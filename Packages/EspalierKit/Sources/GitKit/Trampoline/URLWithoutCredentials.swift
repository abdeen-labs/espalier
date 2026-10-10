// Ported from desktop/app/src/lib/trampoline/url-without-credentials.ts

import EspalierSupport

public func urlWithoutCredentials(_ remoteUrl: String) throws(JSURLError) -> String {
    urlWithoutCredentials(try JSURL(remoteUrl))
}

public func urlWithoutCredentials(_ remoteUrl: JSURL) -> String {
    var url = remoteUrl
    url.username = ""
    url.password = ""
    return url.href
}
