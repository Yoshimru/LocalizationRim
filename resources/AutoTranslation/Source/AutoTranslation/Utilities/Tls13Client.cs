#if RW17
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Authentication;
using System.Text;
using System.Threading;

namespace AutoTranslation.Utilities
{
    /// Google blocks .NET's default TLS ClientHello with a 429 "Sorry..." page: TLS 1.2 connections
    /// are always rejected and the first 1.2+1.3 connection of a process is too (curl from the same
    /// IP gets 200). TLS 1.3-only connections pass, so Google requests go through this client.
    public static class Tls13Client
    {
        private static readonly object gate = new object();
        private static HttpClient client;
        private static volatile bool disabled;

        public static bool IsSupported => !disabled;

        public static void Disable() => disabled = true;

        /// Drops the pooled connections: Google keeps answering 429 on a connection it flagged.
        /// The old client is not disposed (another thread may still be using it); its idle
        /// connections close on their own.
        public static void Reset()
        {
            lock (gate) client = null;
        }

        private static HttpClient GetClient()
        {
            lock (gate)
            {
                if (client == null)
                {
                    var handler = new SocketsHttpHandler
                    {
                        UseCookies = false,
                        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30)
                    };
                    handler.SslOptions.EnabledSslProtocols = SslProtocols.Tls13;
                    client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
                }
                return client;
            }
        }

        /// Throws NotSupportedException when TLS 1.3 cannot be negotiated (e.g. Windows 10 Schannel),
        /// WebException for transport failures (statuses match NetworkHelper.IsConnectionLevelFailure)
        public static string Get(string url, string userAgent, int timeoutMs, out int statusCode)
        {
            using (var request = new HttpRequestMessage(HttpMethod.Get, url))
            using (var cts = new CancellationTokenSource(timeoutMs))
            {
                request.Headers.TryAddWithoutValidation("User-Agent", userAgent);

                HttpResponseMessage response;
                try
                {
                    response = GetClient().Send(request, HttpCompletionOption.ResponseContentRead, cts.Token);
                }
                catch (OperationCanceledException e) when (cts.IsCancellationRequested)
                {
                    throw new WebException("The request timed out", e, WebExceptionStatus.Timeout, null);
                }
                catch (HttpRequestException e) when (e.HttpRequestError == HttpRequestError.SecureConnectionError)
                {
                    throw new NotSupportedException("TLS 1.3 handshake failed: " + (e.InnerException?.Message ?? e.Message), e);
                }
                catch (HttpRequestException e)
                {
                    throw new WebException(e.Message, e, ToWebExceptionStatus(e.HttpRequestError), null);
                }

                using (response)
                using (var stream = response.Content.ReadAsStream())
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    statusCode = (int)response.StatusCode;
                    return reader.ReadToEnd();
                }
            }
        }

        private static WebExceptionStatus ToWebExceptionStatus(HttpRequestError error)
        {
            switch (error)
            {
                case HttpRequestError.NameResolutionError: return WebExceptionStatus.NameResolutionFailure;
                case HttpRequestError.ConnectionError: return WebExceptionStatus.ConnectFailure;
                case HttpRequestError.ResponseEnded: return WebExceptionStatus.ConnectionClosed;
                case HttpRequestError.ProxyTunnelError: return WebExceptionStatus.ProxyNameResolutionFailure;
                default: return WebExceptionStatus.UnknownError;
            }
        }
    }
}
#endif
