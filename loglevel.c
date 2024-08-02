#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/uio.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <elf.h>
#include <dirent.h>
#include <limits.h>

#define MAX_LOGGERS 100
#define MAX_SYMBOL_NAME 256
#define MAX_PROCESS_NAME 256
#define MAX_LINE_LENGTH 512

#define LOG_SYMBOL_NAME "_D4util3logQeSQmQj3Log"

typedef enum {
    TRACE = 1,
    INFO = 2,
    WARN = 4,
    ERROR = 8,
    FATAL = 16
} LogLevel;

typedef struct {
    unsigned long address;
    char name[MAX_SYMBOL_NAME];
    unsigned int level;
} Logger;

typedef struct {
    pid_t pid;
    unsigned long address;
    Logger loggers[MAX_LOGGERS];
    size_t logger_count;
} Log;

const char* decode_log_level(unsigned int level) {
    if (level & TRACE) return "trace";
    if (level & INFO) return "info";
    if (level & WARN) return "warn";
    if (level & ERROR) return "error";
    if (level & FATAL) return "fatal";
    return "unknown";
}

unsigned int encode_log_level(const char* level_str) {
    if (strcasecmp(level_str, "trace") == 0) return TRACE;
    if (strcasecmp(level_str, "info") == 0) return INFO;
    if (strcasecmp(level_str, "warn") == 0) return WARN;
    if (strcasecmp(level_str, "error") == 0) return ERROR;
    if (strcasecmp(level_str, "fatal") == 0) return FATAL;
    return 0;
}

ssize_t read_process_memory(pid_t pid, unsigned long addr, void* buffer, size_t size) {
    struct iovec local[1];
    struct iovec remote[1];

    local[0].iov_base = buffer;
    local[0].iov_len = size;
    remote[0].iov_base = (void*)addr;
    remote[0].iov_len = size;

    return process_vm_readv(pid, local, 1, remote, 1, 0);
}

ssize_t write_process_memory(pid_t pid, unsigned long addr, void* buffer, size_t size) {
    struct iovec local[1];
    struct iovec remote[1];

    local[0].iov_base = buffer;
    local[0].iov_len = size;
    remote[0].iov_base = (void*)addr;
    remote[0].iov_len = size;

    return process_vm_writev(pid, local, 1, remote, 1, 0);
}

unsigned long find_base_address(pid_t pid) {
    char maps_file[64];
    snprintf(maps_file, sizeof(maps_file), "/proc/%d/maps", pid);
    FILE* fp = fopen(maps_file, "r");
    if (!fp) {
        perror("Failed to open maps file");
        return 0;
    }

    /**
     * Return first mapping. They're sorted by start,
     * and the first mapping is always the binary.
     */
    char line[MAX_LINE_LENGTH];
    unsigned long start_address = 0;
    while (fgets(line, sizeof(line), fp)) {
        unsigned long start, end;
        char permissions[5];
        if (sscanf(line, "%lx-%lx %4s", &start, &end, permissions) == 3) {
            start_address = start;
            break;
        }
    }
    fclose(fp);

    if (start_address == 0) {
        fprintf(stderr, "No valid mappings found\n");
    }
    return start_address;
}

unsigned long find_symbol_address(pid_t pid, const char* symbol_name) {
    unsigned long base_addr = find_base_address(pid);
    if (base_addr == 0) {
        fprintf(stderr, "Failed to find executable mapping\n");
        return 0;
    }

    Elf64_Ehdr ehdr;
    if (read_process_memory(pid, base_addr, &ehdr, sizeof(ehdr)) == -1) {
        perror("Failed to read ELF header");
        return 0;
    }

    unsigned long phoff = base_addr + ehdr.e_phoff;
    Elf64_Phdr phdr;
    unsigned long dynamic_addr = 0;

    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (read_process_memory(pid, phoff + i * sizeof(phdr), &phdr, sizeof(phdr)) == -1) {
            perror("Failed to read program header");
            return 0;
        }
        if (phdr.p_type == PT_DYNAMIC) {
            dynamic_addr = base_addr + phdr.p_vaddr;
            break;
        }
    }

    if (dynamic_addr == 0) {
        fprintf(stderr, "Failed to find dynamic section\n");
        return 0;
    }

    unsigned long symtab_addr = 0, strtab_addr = 0;
    Elf64_Dyn dyn;
    for (unsigned long addr = dynamic_addr; ; addr += sizeof(dyn)) {
        if (read_process_memory(pid, addr, &dyn, sizeof(dyn)) == -1) {
            perror("Failed to read dynamic entry");
            return 0;
        }
        if (dyn.d_tag == DT_NULL) break;
        if (dyn.d_tag == DT_SYMTAB) symtab_addr = dyn.d_un.d_ptr;
        if (dyn.d_tag == DT_STRTAB) strtab_addr = dyn.d_un.d_ptr;
    }

    if (symtab_addr == 0 || strtab_addr == 0) {
        fprintf(stderr, "Failed to find symbol table or string table\n");
        return 0;
    }

    Elf64_Sym sym;
    char name[MAX_SYMBOL_NAME];
    for (unsigned long addr = symtab_addr; ; addr += sizeof(sym)) {
        if (read_process_memory(pid, addr, &sym, sizeof(sym)) == -1) {
            perror("Failed to read symbol");
            return 0;
        }
        if (sym.st_name == 0) continue;
        if (read_process_memory(pid, strtab_addr + sym.st_name, name, sizeof(name)) == -1) {
            perror("Failed to read symbol name");
            return 0;
        }
        if (strcmp(name, symbol_name) == 0) {
            return base_addr + sym.st_value;
        }
    }

    fprintf(stderr, "Symbol not found: %s\n", symbol_name);
    return 0;
}

int get_log(pid_t pid, unsigned long log_address, Log* log) {
    log->pid = pid;
    log->address = log_address;
    log->logger_count = 0;

    unsigned long loggers_length, loggers_ptr;
    if (read_process_memory(pid, log_address, &loggers_length, sizeof(loggers_length)) == -1 ||
        read_process_memory(pid, log_address + 8, &loggers_ptr, sizeof(loggers_ptr)) == -1) {
        perror("Failed to read Log struct");
        return -1;
    }

    for (unsigned long i = 0; i < loggers_length && i < MAX_LOGGERS; i++) {
        unsigned long logger_address;
        if (read_process_memory(pid, loggers_ptr + i * 8, &logger_address, sizeof(logger_address)) == -1) {
            perror("Failed to read logger address");
            return -1;
        }

        unsigned long vtable;
        unsigned int levels;
        if (read_process_memory(pid, logger_address, &vtable, sizeof(vtable)) == -1 ||
            read_process_memory(pid, logger_address + 16, &levels, sizeof(levels)) == -1) {
            perror("Failed to read Logger struct");
            return -1;
        }

        unsigned long type_info;
        if (read_process_memory(pid, vtable, &type_info, sizeof(type_info)) == -1) {
            perror("Failed to read vtable");
            return -1;
        }

        unsigned int name_len;
        unsigned long name_ptr;
        if (read_process_memory(pid, type_info + 32, &name_len, sizeof(name_len)) == -1 ||
            read_process_memory(pid, type_info + 40, &name_ptr, sizeof(name_ptr)) == -1) {
            perror("Failed to read TypeInfo");
            return -1;
        }

        if (name_len >= MAX_SYMBOL_NAME) {
            fprintf(stderr, "Logger name too long\n");
            return -1;
        }

        if (read_process_memory(pid, name_ptr, log->loggers[i].name, name_len) == -1) {
            perror("Failed to read logger name");
            return -1;
        }
        log->loggers[i].name[name_len] = '\0';

        log->loggers[i].address = logger_address;
        log->loggers[i].level = levels;
        log->logger_count++;
    }

    return 0;
}

unsigned int get_global_log_level(pid_t pid, unsigned long log_address) {
    unsigned int level;
    if (read_process_memory(pid, log_address + 16, &level, sizeof(level)) == -1) {
        perror("Failed to read global log level");
        return 0;
    }
    return level;
}

int set_log_level(Log* log, int logger_index, unsigned int new_level) {
    if (logger_index < -1 || (size_t)logger_index >= log->logger_count) {
        fprintf(stderr, "Invalid logger index\n");
        return -1;
    }

    if (logger_index == -1) {
        for (size_t i = 0; i < log->logger_count; i++) {
            if (write_process_memory(log->pid, log->loggers[i].address + 16, &new_level, sizeof(new_level)) == -1) {
                perror("Failed to write logger level");
                return -1;
            }
            log->loggers[i].level = new_level;
        }
    } else {
        if (write_process_memory(log->pid, log->loggers[logger_index].address + 16, &new_level, sizeof(new_level)) == -1) {
            perror("Failed to write logger level");
            return -1;
        }
        log->loggers[logger_index].level = new_level;
    }

    unsigned int max_level = 0;
    for (size_t i = 0; i < log->logger_count; i++) {
        if (log->loggers[i].level > max_level) {
            max_level = log->loggers[i].level;
        }
    }

    if (write_process_memory(log->pid, log->address + 16, &max_level, sizeof(max_level)) == -1) {
        perror("Failed to write global log level");
        return -1;
    }

    return 0;
}

pid_t find_process_by_name(const char* name) {
    DIR* dir = opendir("/proc");
    if (!dir) {
        perror("Failed to open /proc");
        return -1;
    }

    pid_t found_pid = -1;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_type != DT_DIR) {
            continue;
        }

        char* endptr;
        long pid = strtol(entry->d_name, &endptr, 10);
        if (*endptr != '\0') {
            continue;
        }

        char exe_path[PATH_MAX];
        char proc_exe[64];
        snprintf(proc_exe, sizeof(proc_exe), "/proc/%ld/exe", pid);
        ssize_t len = readlink(proc_exe, exe_path, sizeof(exe_path) - 1);
        if (len == -1) {
            continue;
        }
        exe_path[len] = '\0';

        const char* base_name = strrchr(exe_path, '/');
        if (base_name && strcmp(base_name + 1, name) == 0) {
            found_pid = pid;
            break;
        }
    }

    closedir(dir);
    return found_pid;
}

void print_usage(const char* program_name) {
    printf("Usage: %s (-p <pid> | -s <process_name>) [logger_index] [new_level]\n", program_name);
    printf("Options:\n");
    printf("  -h, --help             Show this help message and exit\n");
    printf("  -p <pid>               Specify the process ID\n");
    printf("  -s <process_name>      Specify the process name to search for\n");
    printf("  [logger_index]         Optional: Specify the logger index to change (1-based)\n");
    printf("  [new_level]            Optional: Specify the new log level (trace, info, warn, error, fatal)\n");
    printf("\nIf only [new_level] is provided, all loggers will be set to that level.\n");
}

int confirm_action(const char* prompt) {
    printf("%s (y/n): ", prompt);
    char response;
    if (scanf(" %c", &response) != 1) {
        return 0;
    }
    return response == 'y' || response == 'Y';
}

int main(int argc, char* argv[]) {
    if (argc < 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        print_usage(argv[0]);
        return 0;
    }

    pid_t pid = -1;
    int logger_index = -1;
    const char* new_level_str = NULL;

    if (strcmp(argv[1], "-p") == 0 && argc >= 3) {
        char* endptr;
        pid = strtol(argv[2], &endptr, 10);
        if (*endptr != '\0' || pid <= 0) {
            fprintf(stderr, "Invalid PID\n");
            return 1;
        }
        if (argc > 3) {
            if (argc == 4) {
                new_level_str = argv[3];
            } else if (argc == 5) {
                logger_index = atoi(argv[3]) - 1;
                new_level_str = argv[4];
            } else {
                fprintf(stderr, "Too many arguments\n");
                print_usage(argv[0]);
                return 1;
            }
        }
    } else if (strcmp(argv[1], "-s") == 0 && argc >= 3) {
        pid = find_process_by_name(argv[2]);
        if (pid == -1) {
            fprintf(stderr, "Process not found: %s\n", argv[2]);
            return 1;
        }
        if (argc > 3) {
            if (argc == 4) {
                new_level_str = argv[3];
            } else if (argc == 5) {
                logger_index = atoi(argv[3]) - 1;
                new_level_str = argv[4];
            } else {
                fprintf(stderr, "Too many arguments\n");
                print_usage(argv[0]);
                return 1;
            }
        }
    } else {
        fprintf(stderr, "Invalid arguments\n");
        print_usage(argv[0]);
        return 1;
    }

    unsigned long log_addr = find_symbol_address(pid, LOG_SYMBOL_NAME);
    if (log_addr == 0) {
        fprintf(stderr, "Failed to find Log symbol\n");
        return 1;
    }

    Log log;
    if (get_log(pid, log_addr, &log) == -1) {
        fprintf(stderr, "Failed to get Log information\n");
        return 1;
    }

    if (new_level_str) {
        unsigned int new_level = encode_log_level(new_level_str);
        if (new_level == 0) {
            fprintf(stderr, "Invalid log level: %s\n", new_level_str);
            return 1;
        }

        printf("Current log levels:\n");
        printf("Global log level: %s\n", decode_log_level(get_global_log_level(pid, log_addr)));
        for (size_t i = 0; i < log.logger_count; i++) {
            printf("%zu: %s, level: %s\n", i + 1, log.loggers[i].name, decode_log_level(log.loggers[i].level));
        }

        if (!confirm_action("Are you sure you want to change the log level?")) {
            printf("Operation cancelled.\n");
            return 0;
        }

        if (set_log_level(&log, logger_index, new_level) == -1) {
            fprintf(stderr, "Failed to set log level\n");
            return 1;
        }
        printf("Log level updated successfully.\n");
    }

    printf("Global log level: %s\n", decode_log_level(get_global_log_level(pid, log_addr)));
    printf("Configured loggers:\n");
    for (size_t i = 0; i < log.logger_count; i++) {
        printf("%zu: %-30s, level: %s\n", i + 1, log.loggers[i].name, decode_log_level(log.loggers[i].level));
    }

    return 0;
}
