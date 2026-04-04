#include <jni.h>
#include <android/log.h>
#include <csignal>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define LOG_TAG "xrayjni"
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {
static constexpr const char* kBridgeClassName = "com/awmanager/ui/XrayNativeBridge";

std::string JStringToStdString(JNIEnv* env, jstring value) {
    if (value == nullptr) {
        return std::string();
    }
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) {
        return std::string();
    }
    std::string out(chars);
    env->ReleaseStringUTFChars(value, chars);
    return out;
}

int RedirectLog(const std::string& log_path) {
    int fd = open(log_path.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) {
        return -errno;
    }
    if (dup2(fd, STDOUT_FILENO) < 0) {
        int saved = errno;
        close(fd);
        return -saved;
    }
    if (dup2(fd, STDERR_FILENO) < 0) {
        int saved = errno;
        close(fd);
        return -saved;
    }
    if (fd > STDERR_FILENO) {
        close(fd);
    }
    return 0;
}

long SpawnXray(
    const std::string& binary_path,
    const std::string& config_path,
    const std::string& asset_dir,
    const std::string& working_dir,
    const std::string& log_path,
    bool validate_only,
    int* validation_exit_code,
    int tun_fd
) {
    pid_t pid = fork();
    if (pid < 0) {
        return -errno;
    }

    if (pid == 0) {
        if (!working_dir.empty()) {
            chdir(working_dir.c_str());
        }
        const int redirect = RedirectLog(log_path);
        if (redirect < 0) {
            _exit(120);
        }
        setenv("XRAY_LOCATION_ASSET", asset_dir.c_str(), 1);
        chmod(binary_path.c_str(), 0755);

        if (tun_fd >= 0) {
            const int current_flags = fcntl(tun_fd, F_GETFD);
            if (current_flags >= 0) {
                fcntl(tun_fd, F_SETFD, current_flags & ~FD_CLOEXEC);
            }
            const std::string tun_fd_string = std::to_string(tun_fd);
            setenv("XRAY_TUN_FD", tun_fd_string.c_str(), 1);
            setenv("xray.tun.fd", tun_fd_string.c_str(), 1);
        } else {
            unsetenv("XRAY_TUN_FD");
            unsetenv("xray.tun.fd");
        }

        if (validate_only) {
            execl(
                binary_path.c_str(),
                binary_path.c_str(),
                "run",
                "-test",
                "-c",
                config_path.c_str(),
                static_cast<char*>(nullptr)
            );
        } else {
            execl(
                binary_path.c_str(),
                binary_path.c_str(),
                "run",
                "-c",
                config_path.c_str(),
                static_cast<char*>(nullptr)
            );
        }
        dprintf(STDERR_FILENO, "exec failed errno=%d (%s)\n", errno, strerror(errno));
        _exit(127);
    }

    if (validate_only) {
        int status = 0;
        if (waitpid(pid, &status, 0) < 0) {
            return -errno;
        }
        if (WIFEXITED(status)) {
            *validation_exit_code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            *validation_exit_code = 128 + WTERMSIG(status);
        } else {
            *validation_exit_code = 1;
        }
        return 0;
    }

    return static_cast<long>(pid);
}

jint nativeValidate(
    JNIEnv* env,
    jobject /* this */,
    jstring binaryPath,
    jstring configPath,
    jstring assetDir,
    jstring workingDir,
    jstring logPath
) {
    const std::string binary_path = JStringToStdString(env, binaryPath);
    const std::string config_path = JStringToStdString(env, configPath);
    const std::string asset_dir = JStringToStdString(env, assetDir);
    const std::string working_dir = JStringToStdString(env, workingDir);
    const std::string log_path = JStringToStdString(env, logPath);

    int exit_code = 1;
    const long result = SpawnXray(binary_path, config_path, asset_dir, working_dir, log_path, true, &exit_code, -1);
    if (result < 0) {
        ALOGE("validate spawn failed: %ld", result);
        return static_cast<jint>(-1 * result);
    }
    return static_cast<jint>(exit_code);
}

jlong nativeStart(
    JNIEnv* env,
    jobject /* this */,
    jstring binaryPath,
    jstring configPath,
    jstring assetDir,
    jstring workingDir,
    jstring logPath,
    jint tunFd
) {
    const std::string binary_path = JStringToStdString(env, binaryPath);
    const std::string config_path = JStringToStdString(env, configPath);
    const std::string asset_dir = JStringToStdString(env, assetDir);
    const std::string working_dir = JStringToStdString(env, workingDir);
    const std::string log_path = JStringToStdString(env, logPath);

    int ignored_exit_code = 0;
    const long pid = SpawnXray(binary_path, config_path, asset_dir, working_dir, log_path, false, &ignored_exit_code, static_cast<int>(tunFd));
    if (pid < 0) {
        ALOGE("start spawn failed: %ld", pid);
    } else {
        ALOGI("started xray pid=%ld tunFd=%d", pid, static_cast<int>(tunFd));
    }
    return static_cast<jlong>(pid);
}

jboolean nativeStop(
    JNIEnv* /* env */,
    jobject /* this */,
    jlong pid
) {
    if (pid <= 0) {
        return JNI_FALSE;
    }
    if (kill(static_cast<pid_t>(pid), SIGTERM) != 0 && errno != ESRCH) {
        return JNI_FALSE;
    }

    for (int i = 0; i < 20; ++i) {
        if (kill(static_cast<pid_t>(pid), 0) != 0 && errno == ESRCH) {
            return JNI_TRUE;
        }
        usleep(100 * 1000);
    }

    if (kill(static_cast<pid_t>(pid), SIGKILL) != 0 && errno != ESRCH) {
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

jboolean nativeIsRunning(
    JNIEnv* /* env */,
    jobject /* this */,
    jlong pid
) {
    if (pid <= 0) {
        return JNI_FALSE;
    }
    if (kill(static_cast<pid_t>(pid), 0) == 0) {
        return JNI_TRUE;
    }
    return JNI_FALSE;
}
}  // namespace

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /* reserved */) {
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK || env == nullptr) {
        return JNI_ERR;
    }

    jclass bridge = env->FindClass(kBridgeClassName);
    if (bridge == nullptr) {
        ALOGE("failed to find bridge class: %s", kBridgeClassName);
        return JNI_ERR;
    }

    static const JNINativeMethod methods[] = {
        {const_cast<char*>("validate"), const_cast<char*>("(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I"), reinterpret_cast<void*>(nativeValidate)},
        {const_cast<char*>("start"), const_cast<char*>("(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)J"), reinterpret_cast<void*>(nativeStart)},
        {const_cast<char*>("stop"), const_cast<char*>("(J)Z"), reinterpret_cast<void*>(nativeStop)},
        {const_cast<char*>("isRunning"), const_cast<char*>("(J)Z"), reinterpret_cast<void*>(nativeIsRunning)},
    };

    if (env->RegisterNatives(bridge, methods, sizeof(methods) / sizeof(methods[0])) != JNI_OK) {
        ALOGE("RegisterNatives failed for %s", kBridgeClassName);
        return JNI_ERR;
    }
    return JNI_VERSION_1_6;
}
