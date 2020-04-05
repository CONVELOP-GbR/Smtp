import Foundation
import NIO
import NIOSSL
import Vapor

/// This is simple implementation of SMTP client service.
/// The implementation was based on Apple SwiftNIO.
///
/// # Usage
///
/// **Set the SMTP server configuration (main.swift).**
///
///```swift
/// import Smtp
///
/// var env = try Environment.detect()
/// try LoggingSystem.bootstrap(from: &env)
///
/// let app = Application(env)
/// defer { app.shutdown() }
///
/// app.smtp.configuration.host = "smtp.server"
/// app.smtp.configuration.username = "johndoe"
/// app.smtp.configuration.password = "passw0rd"
/// app.smtp.configuration.secure = .ssl
///
/// try configure(app)
/// try app.run()
///```
///
/// **Using SMTP client**
///
///```swift
/// let email = Email(from: EmailAddress(address: "john.doe@testxx.com", name: "John Doe"),
///                   to: [EmailAddress("ben.doe@testxx.com")],
///                   subject: "The subject (text)",
///                   body: "This is email body.")
///
/// request.send(email).map { result in
///     switch result {
///     case .success:
///         print("Email has been sent")
///     case .failure(let error):
///         print("Email has not been sent: \(error)")
///     }
/// }
///```
///
/// Channel pipeline:
///
/// ```
/// +-------------------------------------------------------------------+
/// |                                                                   |
/// |       [ Socket.read ]                    [ Socket.write ]         |
/// |              |                                  |                 |
/// +--------------+----------------------------------+-----------------+
///                |                                 /|\
///               \|/                                 |
///          +-----+----------------------------------+-----+
///          |    OpenSSLClientHandler (enabled/disabled)   |
///          +-----+----------------------------------+-----+
///                |                                 /|\
///               \|/                                 |
///          +-----+----------------------------------+-----+
///          |             DuplexMessagesHandler            |
///          +-----+----------------------------------+-----+
///                |                                 /|\
///               \|/                                 |
///          +-----+--------------------------+       |
///          |  InboundLineBasedFrameDecoder  |       |
///          +-----+--------------------------+       |
///                |                                  |
///               \|/                                 |
///          +-----+--------------------------+       |
///          |   InboundSmtpResponseDecoder   |       |
///          +-----+--------------------------+       |
///                |                                  |
///                |                                  |
///                |       +--------------------------+-----+
///                |       |  OutboundSmtpRequestEncoder    |
///                |       +--------------------------+-----+
///                |                                 /|\
///               \|/                                 |
///          +-----+----------------------------------+-----+
///          |               StartTlsHandler                |
///          +-----+----------------------------------+-----+
///                |                                 /|\
///                |                                  |
///               \|/                                 | [write]
///          +-----+--------------------------+       |
///          |   InboundSendEmailHandler      +-------+
///          +--------------------------------+
///```
/// `OpenSSLClientHandler` is enabled only when `.ssl` secure is defined. For `.none` that
/// handler is not added to the pipeline.
///
/// `StartTlsHandler` is responsible for establishing SSL encryption after `STARTTLS`
/// command (this handler adds dynamically `OpenSSLClientHandler` to the pipeline if
/// server supports that encryption.
public extension Request {

    /// Sending an email.
    ///
    /// - parameters:
    ///     - email: Email which will be send.
    ///     - logHandler: Callback which can be used for logging/printing of sending status messages.
    /// - returns: An `EventLoopFuture<Result<Bool, Error>>` with information about sent email.
    func send(_ email: Email, logHandler: ((String) -> Void)? = nil) -> EventLoopFuture<Result<Bool, Error>> {
        let emailSentPromise: EventLoopPromise<Void> = self.eventLoop.makePromise()
        let configuration = self.application.smtp.configuration
        
        // Client configuration
        let bootstrap = ClientBootstrap(group: self.eventLoop)
            .connectTimeout(configuration.connectTimeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in

                let secureChannelFuture = configuration.secure.configureChannel(on: channel, hostname: configuration.hostname)
                return secureChannelFuture.flatMap {

                    let defaultHandlers: [ChannelHandler] = [
                        DuplexMessagesHandler(handler: logHandler),
                        ByteToMessageHandler(InboundLineBasedFrameDecoder()),
                        InboundSmtpResponseDecoder(),
                        MessageToByteHandler(OutboundSmtpRequestEncoder()),
                        StartTlsHandler(configuration: configuration, allDonePromise: emailSentPromise),
                        InboundSendEmailHandler(configuration: configuration,
                                                email: email,
                                                allDonePromise: emailSentPromise)
                    ]

                    return channel.pipeline.addHandlers(defaultHandlers, position: .last)
                }
            }

        // Connect and send email.
        let connection = bootstrap.connect(host: configuration.hostname, port: configuration.port)
        
        connection.cascadeFailure(to: emailSentPromise)
        
        return emailSentPromise.futureResult.map { () -> Result<Bool, Error> in
            connection.whenSuccess { $0.close(promise: nil) }
            return Result.success(true)
        }.flatMapError { error -> EventLoopFuture<Result<Bool, Error>> in
            return self.eventLoop.makeSucceededFuture(Result.failure(error))
        }
    }
}
