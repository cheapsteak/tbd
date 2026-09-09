import Darwin
import Dispatch
import Foundation

/// Who, if anyone, accepts a TCP connection on a loopback port right now.
enum LoopbackPortOccupancy: Sendable, Equatable {
    /// The connect was refused: no socket is listening. A transient holder
    /// of the number (a client socket bound to it) looks exactly like this.
    case refused
    /// Something accepted the connection — a listener, ours or a stranger's.
    case accepted
    /// Neither answer inside the bound (a listener with a full backlog, or
    /// an errno that is not ECONNREFUSED). Carried for the log line.
    case undetermined(String)
}

/// The one question `ModelProxySupervisor`'s port wait turns on, as a protocol
/// so a test can force an answer for a port a fake has just released.
protocol LoopbackPortProbing: Sendable {
    func occupancy(port: Int) async -> LoopbackPortOccupancy
}

/// A plain non-blocking `connect(2)` to `127.0.0.1:<port>`, and nothing else.
///
/// **Why this sits beside `ModelProxyClient` rather than inside it.** The
/// client speaks the control protocol, and every transport failure it can meet
/// — a refused connect, a listener that accepts and then says nothing, a
/// listener that answers something that is not a status document — folds into
/// one `unreachable` error. That fold is right for the client's callers, who
/// only ever want "is this a proxy I may adopt". It is wrong for the
/// supervisor's port wait, which has to tell a *transient holder of the number*
/// from a *listener*, and the errno is the only discriminator: a refused
/// connect means nothing is listening, so the number is held by a client socket
/// that will let go of it and the wait is worth paying; an accepted connect
/// means a listener, and a listener that failed the adoption identity check
/// will still be there in two seconds and in thirty.
///
/// **The one-second poll bound is a transport deadline, not a sleep.** It is
/// the same kind of bound as `ModelProxyClient`'s two-second `URLSession`
/// timeout and takes no injected clock for the same reason: there is nothing
/// here to fake, the connect either lands or it does not. Loopback answers
/// instantly in both of the cases this probe exists to tell apart — a listening
/// socket accepts in the kernel without ever waking its accept loop, and a port
/// with no listener is refused by the same stack — so the bound is only ever
/// spent on the pathological third case (a listener whose backlog is full),
/// which is reported as `.undetermined` and treated as a transient.
///
/// **The syscalls run on a GCD thread, never on the cooperative pool.** That
/// pool is only as wide as the machine has cores — three on a CI runner — and a
/// thread blocked in `poll(2)` there is one the supervisor's actor and every
/// other task on the machine cannot use for as long as the bound lasts. A
/// blocking syscall with a hard one-second ceiling is exactly what GCD's global
/// queue is for, so the probe hops to it and suspends its caller instead.
struct LoopbackPortProbe: LoopbackPortProbing {
    /// How long a connect that went asynchronous may take before the answer is
    /// `.undetermined`.
    static let connectBoundMilliseconds: Int32 = 1000

    func occupancy(port: Int) async -> LoopbackPortOccupancy {
        await withCheckedContinuation { (continuation: CheckedContinuation<LoopbackPortOccupancy, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: LoopbackPortProbe.probe(port: port))
            }
        }
    }

    /// The syscall sequence itself, synchronous and off the cooperative pool.
    private static func probe(port: Int) -> LoopbackPortOccupancy {
        guard let networkPort = UInt16(exactly: port), networkPort > 0 else {
            return .undetermined("\(port) is not a port number")
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .undetermined(Self.describe(errno)) }
        // Always, on every path out: a probe that leaked a descriptor per
        // attempt would exhaust the daemon's table over a long wait.
        defer { Darwin.close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return .undetermined(Self.describe(errno))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(networkPort).bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return .accepted }

        let connectErrno = errno
        switch connectErrno {
        case ECONNREFUSED: return .refused
        case EINPROGRESS: break
        default: return .undetermined(Self.describe(connectErrno))
        }

        // The connect went asynchronous, which on loopback still settles in
        // microseconds. `POLLOUT` is how a non-blocking connect reports that it
        // has finished, success or failure alike; `SO_ERROR` is what it
        // finished with.
        var watched = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &watched) { pointer in
            Darwin.poll(pointer, 1, Self.connectBoundMilliseconds)
        }
        guard ready > 0 else {
            if ready == 0 { return .undetermined("no answer within 1s") }
            return .undetermined(Self.describe(errno))
        }

        var pending: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 else {
            return .undetermined(Self.describe(errno))
        }
        switch pending {
        case 0: return .accepted
        case ECONNREFUSED: return .refused
        default: return .undetermined(Self.describe(pending))
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
