import Foundation
@testable import RefillCore

/// A MikroTik HotSpot with a free trial: RouterOS 7.25.1 (CHR, in QEMU) with its own login pages, recorded with curl on
/// 2026-11-05: a hotspot on ether1, `login-by=http-chap,trial`. The hotspot address is replaced by the default hotspot
/// network's 10.5.50.1 and the client's hardware address by 02:00:00:00:00:01; the CHAP challenge is as sent. The
/// redirect from Apple's check page is not recorded (the client was the VM's host, not routed through the hotspot): it
/// is `$(link-login)` as MikroTik documents it, the login address with `dst`.
enum MikroTikFixture {
    static let router = "10.5.50.1"
    static let network = LocalNetwork(interface: "en0", router: router, address: "10.5.50.254", mask: "255.255.255.0")
    static let dst = "dst=http%3A%2F%2Fcaptive.apple.com%2Fhotspot-detect.html"
    static let login = "http://\(router)/login?\(dst)"
    static let trialQuery = "\(dst)&username=T-02%3A00%3A00%3A00%3A00%3A01"
    static let trialLink = "http://10.5.50.1/login?dst=http%3A%2F%2Fcaptive.apple.com%2Fhotspot-detect.html&amp;username=T-02%3A00%3A00%3A00%3A00%3A01"

    /// login.html with a trial on offer, or with `trial` in place of its trial link; nil leaves the page as it is
    /// without a trial.
    static func page(trial: String? = trialLink) -> String {
        guard let trial else { return loginPage.replacingOccurrences(of: #"<br />Free trial available, <a href="\#(trialLink)">click here</a>."#, with: "<br />") }
        return loginPage.replacingOccurrences(of: trialLink, with: trial)
    }

    static let loginPage = #"""
        <!doctype html>
        <html lang="en">

        <head>
            <meta charset="utf-8">
            <meta http-equiv="pragma" content="no-cache" />
            <meta http-equiv="expires" content="-1" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Internet hotspot - Log in</title>
            <link rel="stylesheet" href="css/style.css">
        </head>

        <body>

            <!-- two other colors

        <body class="lite">
        <body class="dark">

        -->


            <form name="sendin" action="http://10.5.50.1/login" method="post" style="display:none">
                <input type="hidden" name="username" />
                <input type="hidden" name="password" />
                <input type="hidden" name="dst" value="http://captive.apple.com/hotspot-detect.html" />
                <input type="hidden" name="popup" value="true" />
            </form>

            <script src="/md5.js"></script>
            <script>
                function doLogin() {
                    document.sendin.username.value = document.login.username.value;
                    document.sendin.password.value = hexMD5('\321' + document.login.password.value + '\176\004\241\147\255\363\241\325\321\207\364\331\103\271\023\022');
                    document.sendin.submit();
                    return false;
                }

            </script>

            <div class="ie-fixMinHeight">
                <div class="main">
                    <div class="wrap animated fadeIn">
                        <form name="login" action="http://10.5.50.1/login" method="post"  onSubmit="return doLogin()" >
                            <input type="hidden" name="dst" value="http://captive.apple.com/hotspot-detect.html" />
                            <input type="hidden" name="popup" value="true" />
                            <svg class="logo" data-name="Layer 1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 174 42">
                                <path fill="#fff" d="M7.32 13.66L0 41.74 3.12 41.74 9.49 15.94 9.58 15.94 15.01 41.74 18.22 41.74 36.86 16.34 36.95 16.34 30.02 41.74 33.18 41.74 40.4 13.66 35.73 13.66 17.23 38.87 11.99 13.66 7.32 13.66zM43.43 21.45L38.19 41.74 41.16 41.74 46.4 21.45 43.43 21.45zM50.68 21.45L45.5 41.74 48.47 41.74 50.36 34.39 55.55 30.77 62.02 41.74 65.27 41.74 57.91 29.28 69.43 21.45 65.46 21.45 51.21 31.36 51.12 31.28 53.66 21.45 50.68 21.45z" />
                                <path d="M71.18 21.45L65.94 41.74h3l2.74-10.62c1-3.81 3.82-7.39 9.16-7.47.56 0 1.13 0 1.7 0l.66-2.48c-.52 0-1.09 0-1.61 0-4.34 0-6.94 2-8.82 5h-.1l1.23-4.68zM103.8 28.8c0-5-4-7.94-9.63-7.94-8.69 0-13.59 6.37-13.59 13 0 5.07 3.44 8.45 9.72 8.45 9 0 13.5-6.68 13.5-13.53m-3 .52c0 4.72-3.44 10.93-9.95 10.93-5 0-7.32-2.68-7.32-6.61 0-4.76 3.59-10.7 10.1-10.7 4.77 0 7.17 2.6 7.17 6.38M132.33 21.43L134.26 13.66 105.19 13.66 103.27 21.45 112.59 21.45 112.59 21.45 122.99 21.45 122.99 21.45 132.33 21.43zM111.67 25.17L107.55 41.74 117.93 41.74 122.06 25.17 122.06 25.16 111.67 25.16 111.67 25.17zM134 25.17l-4.11 16.57h9.35l4.1-16.57zm10.28-3.73l1.94-7.78h-9.34l-2 7.79zM150.09 13.66L143.11 41.74 152.45 41.74 153.91 35.92 156.04 34.34 159.34 41.74 169.49 41.74 163.26 29.55 174.26 21.33 163.07 21.33 156.18 27.3 156.09 27.3 159.44 13.66 150.09 13.66zM47.45 0c1.14 7.93 5.39 12.74 14.07 13.14A10.69 10.69 0 0 1 47.45 0" fill="#fff" fill-rule="evenodd" />
                                <path d="M42.91,1.4c.1,0,.11,0,.12.11A16.55,16.55,0,0,0,48.26,13a16.6,16.6,0,0,0,12,4.66c-10,4-20.55-5.6-17.33-16.28" fill="#fff" fill-rule="evenodd" /></svg>


                            <p class="info ">
                                Please log in to use the internet hotspot service <br />Free trial available, <a href="http://10.5.50.1/login?dst=http%3A%2F%2Fcaptive.apple.com%2Fhotspot-detect.html&amp;username=T-02%3A00%3A00%3A00%3A00%3A01">click here</a>.



                            </p>
                            <label>
                                <img class="ico" src="img/user.svg" alt="#" />
                                <input name="username" type="text" value="" placeholder="Username" />
                            </label>

                            <label>
                                <img class="ico" src="img/password.svg" alt="#" />
                                <input name="password" type="password" placeholder="Password" />
                            </label>

                            <input type="submit" value="Connect" />

                        </form>
                        <p class="info bt">Powered by MikroTik RouterOS</p>

                    </div>
                </div>
            </div>
        </body>

        </html>
        """#

    /// alogin.html, after the trial link.
    static let loggedIn = #"""
        <!doctype html>
        <html lang="en">

        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <meta http-equiv="refresh" content="2; url=http://captive.apple.com/hotspot-detect.html">
            <meta http-equiv="pragma" content="no-cache">
            <meta http-equiv="expires" content="-1">
            <title>Internet hotspot - Redirect</title>
            <link rel="stylesheet" href="css/style.css">
            <script>
                function startClock() {

                    open('http://10.5.50.1/status', 'hotspot_status', 'toolbar=0,location=0,directories=0,status=0,menubars=0,resizable=1,width=290,height=200');

                location.href = unescape('http%3A%2F%2Fcaptive.apple.com%2Fhotspot-detect.html');
                }

            </script> 
        </head>

        <body onLoad="startClock()">
            <div class="ie-fixMinHeight">
                <div class="main">
                    <div class="wrap">
                        <h1>You are logged in</h1>
                        <p class="info">If nothing happens, click <a href="http://captive.apple.com/hotspot-detect.html">here</a></p>
                    </div>
                </div>
            </div>
        </body>

        </html>
        """#

    /// The trial link with trial turned off: login.html again, with the error.
    static let refused = #"""
        <!doctype html>
        <html lang="en">

        <head>
            <meta charset="utf-8">
            <meta http-equiv="pragma" content="no-cache" />
            <meta http-equiv="expires" content="-1" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Internet hotspot - Log in</title>
            <link rel="stylesheet" href="css/style.css">
        </head>

        <body>

            <!-- two other colors

        <body class="lite">
        <body class="dark">

        -->


            <form name="sendin" action="http://10.5.50.1/login" method="post" style="display:none">
                <input type="hidden" name="username" />
                <input type="hidden" name="password" />
                <input type="hidden" name="dst" value="http://captive.apple.com/hotspot-detect.html" />
                <input type="hidden" name="popup" value="true" />
            </form>

            <script src="/md5.js"></script>
            <script>
                function doLogin() {
                    document.sendin.username.value = document.login.username.value;
                    document.sendin.password.value = hexMD5('\135' + document.login.password.value + '\140\042\212\110\245\022\146\224\265\117\221\217\133\234\377\347');
                    document.sendin.submit();
                    return false;
                }

            </script>

            <div class="ie-fixMinHeight">
                <div class="main">
                    <div class="wrap animated fadeIn">
                        <form name="login" action="http://10.5.50.1/login" method="post"  onSubmit="return doLogin()" >
                            <input type="hidden" name="dst" value="http://captive.apple.com/hotspot-detect.html" />
                            <input type="hidden" name="popup" value="true" />
                            <svg class="logo" data-name="Layer 1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 174 42">
                                <path fill="#fff" d="M7.32 13.66L0 41.74 3.12 41.74 9.49 15.94 9.58 15.94 15.01 41.74 18.22 41.74 36.86 16.34 36.95 16.34 30.02 41.74 33.18 41.74 40.4 13.66 35.73 13.66 17.23 38.87 11.99 13.66 7.32 13.66zM43.43 21.45L38.19 41.74 41.16 41.74 46.4 21.45 43.43 21.45zM50.68 21.45L45.5 41.74 48.47 41.74 50.36 34.39 55.55 30.77 62.02 41.74 65.27 41.74 57.91 29.28 69.43 21.45 65.46 21.45 51.21 31.36 51.12 31.28 53.66 21.45 50.68 21.45z" />
                                <path d="M71.18 21.45L65.94 41.74h3l2.74-10.62c1-3.81 3.82-7.39 9.16-7.47.56 0 1.13 0 1.7 0l.66-2.48c-.52 0-1.09 0-1.61 0-4.34 0-6.94 2-8.82 5h-.1l1.23-4.68zM103.8 28.8c0-5-4-7.94-9.63-7.94-8.69 0-13.59 6.37-13.59 13 0 5.07 3.44 8.45 9.72 8.45 9 0 13.5-6.68 13.5-13.53m-3 .52c0 4.72-3.44 10.93-9.95 10.93-5 0-7.32-2.68-7.32-6.61 0-4.76 3.59-10.7 10.1-10.7 4.77 0 7.17 2.6 7.17 6.38M132.33 21.43L134.26 13.66 105.19 13.66 103.27 21.45 112.59 21.45 112.59 21.45 122.99 21.45 122.99 21.45 132.33 21.43zM111.67 25.17L107.55 41.74 117.93 41.74 122.06 25.17 122.06 25.16 111.67 25.16 111.67 25.17zM134 25.17l-4.11 16.57h9.35l4.1-16.57zm10.28-3.73l1.94-7.78h-9.34l-2 7.79zM150.09 13.66L143.11 41.74 152.45 41.74 153.91 35.92 156.04 34.34 159.34 41.74 169.49 41.74 163.26 29.55 174.26 21.33 163.07 21.33 156.18 27.3 156.09 27.3 159.44 13.66 150.09 13.66zM47.45 0c1.14 7.93 5.39 12.74 14.07 13.14A10.69 10.69 0 0 1 47.45 0" fill="#fff" fill-rule="evenodd" />
                                <path d="M42.91,1.4c.1,0,.11,0,.12.11A16.55,16.55,0,0,0,48.26,13a16.6,16.6,0,0,0,12,4.66c-10,4-20.55-5.6-17.33-16.28" fill="#fff" fill-rule="evenodd" /></svg>


                            <p class="info alert">


                                web browser did not send challenge response (try again, enable JavaScript)
                            </p>
                            <label>
                                <img class="ico" src="img/user.svg" alt="#" />
                                <input name="username" type="text" value="T-02:00:00:00:00:01" placeholder="Username" />
                            </label>

                            <label>
                                <img class="ico" src="img/password.svg" alt="#" />
                                <input name="password" type="password" placeholder="Password" />
                            </label>

                            <input type="submit" value="Connect" />

                        </form>
                        <p class="info bt">Powered by MikroTik RouterOS</p>

                    </div>
                </div>
            </div>
        </body>

        </html>
        """#

    static func routes(login: String = login, page: String = page(), answer: FakeNetwork.Response = .init(body: loggedIn)) -> [String: FakeNetwork.Response] {
        [
            // rlogin.html: a redirect to $(link-login).
            "captive.apple.com/hotspot-detect.html": .init(status: 302, location: login),
            "\(router)/login": .init(body: page),
            "\(router)/login?\(trialQuery)": answer,
        ]
    }
}
