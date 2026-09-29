import Darwin
import Foundation

extension ScriptRunner {
    // MARK: posix_spawn

    struct SpawnedChild {
        var pid: pid_t
        var stdinFD: Int32
        var stdoutFD: Int32
        var stderrFD: Int32
    }

    /// Spawns `executable` as the leader of a new process group with the three
    /// standard streams on fresh pipes. Every other descriptor is closed in the
    /// child (`POSIX_SPAWN_CLOEXEC_DEFAULT`), and signal dispositions are reset.
    static func spawn(executable: String, arguments: [String],
                              environment: [String: String], directory: String) throws -> SpawnedChild {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            for descriptor in inPipe + outPipe + errPipe where descriptor >= 0 { close(descriptor) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        // Parent ends: not inherited by unrelated children, and a dead reader
        // must not raise SIGPIPE in this process.
        for descriptor in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults)
        sigemptyset(&mask)
        for sig in Int32(1)..<32 where sig != SIGKILL && sig != SIGSTOP { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for argument in argv { free(argument) }
            for argument in envp { free(argument) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        // The child holds its own copies; the parent must drop these so EOF arrives.
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard spawnResult == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .ENOEXEC)
        }
        return SpawnedChild(pid: pid, stdinFD: inPipe[1], stdoutFD: outPipe[0], stderrFD: errPipe[0])
    }

    /// Blocking write of all of `data`; stops quietly on EPIPE (child closed stdin).
    static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Reads `descriptor` until EOF, the byte ceiling, or `stop` once the pipe goes
    /// idle. Always closes `descriptor`.
    static func pump(fd descriptor: Int32, ceiling: Int, control: RunControl, stop: RunFlag,
                             onChunk: (Data) -> Void) -> Data {
        defer { close(descriptor) }
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var pfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 {
                if stop.isSet { break }
                continue
            }
            let bytesRead = read(descriptor, &buffer, buffer.count)
            if bytesRead < 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
            if bytesRead == 0 { break }
            let chunk = Data(buffer[0..<bytesRead])
            accumulated.append(chunk)
            onChunk(chunk)
            if accumulated.count >= ceiling {
                control.request(.truncated)
                accumulated.append(Data("\n[output truncated]".utf8))
                break
            }
        }
        return accumulated
    }
}
