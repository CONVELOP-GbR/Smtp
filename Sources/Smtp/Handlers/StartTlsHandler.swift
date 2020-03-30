import NIO
import NIOSSL

internal final class StartTlsHandler: ChannelDuplexHandler {
    typealias InboundIn = SmtpResponse
    typealias InboundOut = SmtpResponse
    typealias OutboundIn = SmtpRequest
    typealias OutboundOut = SmtpRequest

    private let serverConfiguration: SmtpServerConfiguration
    private let allDonePromise: EventLoopPromise<Void>
    private var waitingForStartTlsResponse = false

    init(configuration: SmtpServerConfiguration, allDonePromise: EventLoopPromise<Void>) {
        self.serverConfiguration = configuration
        self.allDonePromise = allDonePromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {

        if self.startTlsDisabled() {
            context.fireChannelRead(data)
            return
        }

        if waitingForStartTlsResponse {
            self.waitingForStartTlsResponse = false

            let result = self.unwrapInboundIn(data)
            switch result {
            case .error(let message):
                if self.serverConfiguration.secure == .startTls {
                    // Fail only if tls is required.
                    self.allDonePromise.fail(SmtpError(message))
                    return
                }

                // Tls is not required, we can continue without encryption.
                let startTlsResult = self.wrapInboundOut(.ok(200, "STARTTLS is not supported"))
                context.fireChannelRead(startTlsResult)
                return
            case .ok:
                self.initializeTlsHandler(context: context, data: data)
            }
        } else {
            context.fireChannelRead(data)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {

        if self.startTlsDisabled() {
            context.write(data, promise: promise)
            return
        }

        let command = self.unwrapOutboundIn(data)
        switch command {
        case .startTls:
            self.waitingForStartTlsResponse = true
        default:
            break
        }


        context.write(data, promise: promise)
    }

    private func initializeTlsHandler(context: ChannelHandlerContext, data: NIOAny) {
        do {
            let sslContext = try NIOSSLContext(configuration: .forClient())
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: self.serverConfiguration.hostname)
            _ = context.channel.pipeline.addHandler(sslHandler, name: "SSLHandler", position: .first)

            context.fireChannelRead(data)
            _ = context.channel.pipeline.removeHandler(name: "SSLHandler")
        } catch let error {
            self.allDonePromise.fail(error)
        }
    }

    private func startTlsDisabled() -> Bool {
        return self.serverConfiguration.secure != .startTls && self.serverConfiguration.secure != .startTlsWhenAvailable
    }
}
