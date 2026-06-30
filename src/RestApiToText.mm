// RestApiToText — macOS port
// Original Windows plugin: "REST API To Text" by Jeffrey Smith (GPL v3).
// https://github.com/eljefe7000/RestApiToText
//
// Reads a REST request (verb, URL, headers, body, options) written into the
// active editor tab, performs the HTTP(S) call, and writes the response back
// into the editor (a new tab by default, or the same page on request).
//
// The request-parsing logic is ported VERBATIM from the Windows source
// (PluginDefinition.cpp): the first line is "<VERB> <URL>", optional
// **Headers** / **Body** / **RestApiToTextOptions** sections follow, $(ENV:NAME)
// references are expanded from the process environment, JSON responses are
// pretty-printed, and the ShowResponseHeaders / ShowResponseOnSamePage options
// are honoured. Only the platform layer changes:
//
//   WinINet transport            → NSURLSession (synchronous via a dispatch
//     (InternetOpen / InternetConnect / HttpOpenRequest / HttpSendRequest /
//      HttpQueryInfo / InternetReadFile)  semaphore — full HTTPS, all verbs,
//                                          headers and body)
//   ::SendMessage(...)           → nppData._sendMessage(...)
//   Win32 DIALOG (About / Help)  → programmatic AppKit NSWindow (modal)
//   MessageBox                   → NSAlert
//   ShellExecute(url)            → -[NSWorkspace openURL:]
//   _dupenv_s / GetEnvironmentVar→ getenv()
//
// HOST NOTE: the "open the response in a new tab" behaviour relies on
// NPPM_MENUCOMMAND with IDM_FILE_NEW (41001). The macOS host DOES implement
// that IDM (NppPluginManager.mm → newDocument:), so no host change is needed.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <map>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

using std::string;
using std::wstring;

// ── plugin-wide state ────────────────────────────────────────────────────────
static const char *PLUGIN_NAME = "REST API To Text";
static const int   nbFunc      = 3;

NppData  nppData;          // global so _sendMessage resolves everywhere
FuncItem funcItem[nbFunc];

// ── platform helpers ─────────────────────────────────────────────────────────
static NppHandle currentScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    if (which == -1) return 0;
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(h, msg, w, l);
}

static void showAlert(const char *title, const char *msg) {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = title ? [NSString stringWithUTF8String:title] : @"";
        alert.informativeText = msg ? [NSString stringWithUTF8String:msg] : @"";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  String helpers — ported verbatim from the Windows source.
// ─────────────────────────────────────────────────────────────────────────────
static void ToUpper(string *token) {
    std::transform(token->begin(), token->end(), token->begin(),
                   [](unsigned char c) { return (char)std::toupper(c); });
}

static void LTrim(string *token) {
    token->erase(token->begin(), std::find_if(token->begin(), token->end(),
                 [](unsigned char c) { return !std::isspace(c); }));
}

static bool EndsWith(const string &stringToSearch, const string &stringToFind) {
    return (stringToSearch.length() >= stringToFind.length() &&
            stringToSearch.compare(stringToSearch.length() - stringToFind.length(),
                                   stringToFind.length(), stringToFind) == 0);
}

// Look up an environment variable. `envVar` still carries the "ENV:" tag prefix;
// `tag` is "ENV:". Windows used _dupenv_s; macOS uses getenv().
static bool GetEnvironmentVar(string envVar, string tag, string &returnValue) {
    string sEnvVar = envVar.substr(tag.length());
    const char *v = ::getenv(sEnvVar.c_str());
    if (v) { returnValue = v; return true; }
    return false;
}

// Expand every $(ENV:NAME) reference inside tmpToken, appending the result to
// returnValue. Faithful port of InjectEnvironmentVars().
static void InjectEnvironmentVars(string tmpToken, string varStartTag, string varEndTag,
                                  string envTag, string &returnValue) {
    int currPos = 0;
    string tmpBody;

    while (tmpToken.length() >= varStartTag.length() + varEndTag.length() &&
           tmpToken.find(varStartTag.c_str(), 0) != string::npos) {
        size_t startTagPos = tmpToken.find(varStartTag, currPos);
        if (startTagPos != string::npos) {
            size_t endTagPos = tmpToken.find(varEndTag, startTagPos + 2);
            if (endTagPos != string::npos) {
                startTagPos += 2;
                string contents = tmpToken.substr(startTagPos, endTagPos - startTagPos);
                size_t colonPos = contents.find(":", 0);
                if (colonPos != string::npos && colonPos > 0) {
                    string tag = contents.substr(0, colonPos + 1);
                    ToUpper(&tag);
                    if (tag == envTag) {
                        string envValue;
                        if (!GetEnvironmentVar(contents, envTag, envValue)) {
                            string missing = contents.substr(envTag.length());
                            string errorMessage = "Could not find environment variable \"" +
                                missing + "\".  If Nextpad++ was running when you created the "
                                "variable, try closing and reopening it.";
                            showAlert("RestApiToText", errorMessage.c_str());
                            break;
                        } else {
                            string newContents = tmpToken.substr(0, startTagPos - 2);
                            newContents += envValue;
                            tmpBody += newContents;
                            tmpToken = tmpToken.substr(endTagPos + 1);
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        } else {
            break;
        }
    }

    returnValue += tmpBody += tmpToken;
}

// URL-encode (kept for parity with the Windows source; unused by the parser
// just as on Windows, but preserved verbatim).
__attribute__((unused))
static string UrlEncode(string queryString) {
    std::ostringstream escaped;
    escaped.fill('0');
    escaped << std::hex;
    for (string::const_iterator i = queryString.begin(), n = queryString.end(); i != n; ++i) {
        string::value_type c = (*i);
        if (isalnum((unsigned char)c) || c == '-' || c == '_' || c == '.' || c == '~') {
            escaped << c;
            continue;
        }
        escaped << std::uppercase;
        escaped << '%' << std::setw(2) << int((unsigned char)c);
        escaped << std::nouppercase;
    }
    return escaped.str();
}

// Pretty-print a JSON string by indenting on structural delimiters. Verbatim
// port of FormatResponseIntoJson() (delimiter-aware, quote/escape-aware).
static string FormatResponseIntoJson(string response) {
    string json;
    bool isEscaped = false;
    bool insideQuotedString = false;
    std::unordered_set<char> delimiters = { '{', '}', '[', ']', ',' };
    int nbrTabs = 0;

    for (size_t i = 0; i < response.length(); i++) {
        if (response[i] == '"' && !isEscaped)
            insideQuotedString = !insideQuotedString;

        isEscaped = (response[i] == '\\');

        if (!insideQuotedString && delimiters.find(response[i]) != delimiters.end()) {
            switch (response[i]) {
                case '{':
                case '[':
                    nbrTabs++;
                    json.push_back(response[i]);
                    json.push_back('\n');
                    for (int t = 0; t < nbrTabs; t++) json.push_back('\t');
                    break;
                case '}':
                case ']':
                    nbrTabs--;
                    json.push_back('\n');
                    for (int t = 0; t < nbrTabs; t++) json.push_back('\t');
                    json.push_back(response[i]);
                    break;
                case ',':
                    json.push_back(response[i]);
                    json.push_back('\n');
                    for (int t = 0; t < nbrTabs; t++) json.push_back('\t');
                    break;
            }
        } else {
            json.push_back(response[i]);
        }
    }

    return json;
}

// ─────────────────────────────────────────────────────────────────────────────
//  HTTP transport — NSURLSession replacement for WinINet.
//  Performs ONE synchronous request and returns the parsed pieces the caller
//  needs (status, raw header block, body) so the rest of the port can stay
//  faithful to the Windows control flow.
// ─────────────────────────────────────────────────────────────────────────────
struct HttpResult {
    bool    transportError = false;   // could not reach the server at all
    string  transportErrorText;       // human-readable transport failure
    long    statusCode = 0;           // HTTP status code (e.g. 200)
    string  statusText;               // reason phrase (e.g. "OK")
    string  rawHeaders;               // "HTTP/1.1 200 OK\r\nHeader: value\r\n..."
    string  contentType;              // value of the Content-Type response header
    string  body;                     // raw response body
};

// Build a "Name: value" raw-header block (Windows builds this with
// HTTP_QUERY_RAW_HEADERS_CRLF). We synthesise the status line ourselves.
static string buildRawHeaders(NSHTTPURLResponse *http) {
    if (!http) return "";
    std::ostringstream os;
    os << "HTTP/1.1 " << (long)http.statusCode << " "
       << [[NSHTTPURLResponse localizedStringForStatusCode:http.statusCode] UTF8String]
       << "\r\n";
    for (NSString *key in http.allHeaderFields) {
        NSString *val = http.allHeaderFields[key];
        os << [key UTF8String] << ": " << [val UTF8String] << "\r\n";
    }
    return os.str();
}

static HttpResult performHttpRequest(const string &verb,
                                     const string &domain,
                                     int port,
                                     const string &path,
                                     bool https,
                                     const std::map<string, string> &headers,
                                     const string &body) {
    HttpResult result;
    @autoreleasepool {
        // Reconstruct the absolute URL from the parsed pieces.
        string scheme = https ? "https" : "http";
        bool defaultPort = (https && port == 443) || (!https && port == 80) || port == 0;
        std::ostringstream urlStr;
        urlStr << scheme << "://" << domain;
        if (!defaultPort) urlStr << ":" << port;
        // path already begins with '/', or is empty.
        if (path.empty()) urlStr << "/";
        else              urlStr << path;

        NSString *urlString = [NSString stringWithUTF8String:urlStr.str().c_str()];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            result.transportError = true;
            result.transportErrorText = "Invalid URL: " + urlStr.str();
            return result;
        }

        NSMutableURLRequest *req =
            [NSMutableURLRequest requestWithURL:url
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:60.0];
        req.HTTPMethod = [NSString stringWithUTF8String:verb.c_str()];
        [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

        for (std::map<string, string>::const_iterator it = headers.begin();
             it != headers.end(); ++it) {
            [req setValue:[NSString stringWithUTF8String:it->second.c_str()]
               forHTTPHeaderField:[NSString stringWithUTF8String:it->first.c_str()]];
        }

        // Body for the verbs that carry one (matches the Windows guard).
        if ((verb == "POST" || verb == "PUT" || verb == "DELETE" || verb == "PATCH") &&
            !body.empty()) {
            req.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
        }

        // Synchronous call via a dispatch semaphore (NSURLSession is async-only).
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

        __block NSData *outData = nil;
        __block NSURLResponse *outResp = nil;
        __block NSError *outErr = nil;

        NSURLSessionDataTask *task =
            [session dataTaskWithRequest:req
                       completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                outData = d;
                outResp = r;
                outErr  = e;
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        [session finishTasksAndInvalidate];

        if (outErr && !outResp) {
            result.transportError = true;
            result.transportErrorText =
                string("Call failed.  ") + [[outErr localizedDescription] UTF8String] + "\n";
            return result;
        }

        NSHTTPURLResponse *http =
            [outResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)outResp : nil;
        if (http) {
            result.statusCode = http.statusCode;
            result.statusText =
                [[NSHTTPURLResponse localizedStringForStatusCode:http.statusCode] UTF8String];
            result.rawHeaders = buildRawHeaders(http);
            NSString *ct = nil;
            for (NSString *key in http.allHeaderFields) {
                if ([key caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
                    ct = http.allHeaderFields[key];
                    break;
                }
            }
            if (ct) result.contentType = [ct UTF8String];
        }

        if (outData && outData.length > 0)
            result.body.assign((const char *)outData.bytes, outData.length);
    }
    return result;
}

// Mirror the Windows CheckForError(): prepend an error line for any non-2xx
// (other than 200/201) status, matching the original wording/format.
static string CheckForError(const HttpResult &r) {
    string response;
    long statusCode = r.statusCode;

    if (statusCode != 0 && (statusCode / 100) > 2) {
        std::ostringstream os;
        os << statusCode << " - ";
        response.append(os.str());
    }

    if (statusCode != 200 /* HTTP_STATUS_OK */ &&
        statusCode != 201 /* HTTP_STATUS_CREATED */) {
        if (!r.statusText.empty()) {
            response.append(r.statusText);
            response.append("\n\n");
        }
    }

    return response;
}

// ─────────────────────────────────────────────────────────────────────────────
//  MakeRestCall — the core command. Parsing is a verbatim port; transport is
//  the NSURLSession path above.
// ─────────────────────────────────────────────────────────────────────────────
static void MakeRestCall() {
    @autoreleasepool {
        NppHandle curScintilla = currentScintilla();
        if (!curScintilla) return;
        int which = -1;
        nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);

        size_t start = (size_t)sci(curScintilla, SCI_GETSELECTIONSTART);
        size_t end   = (size_t)sci(curScintilla, SCI_GETSELECTIONEND);

        if (end < start) std::swap(start, end);

        size_t asciiTextLen = end - start;

        // Mirror the Windows behaviour: if nothing is selected, select the whole
        // document and operate on that.
        std::vector<char> selBuf;
        if (asciiTextLen == 0) {
            size_t allTextLength = (size_t)sci(curScintilla, SCI_GETLENGTH);
            sci(curScintilla, SCI_SETSELECTIONSTART, 0, 0);
            sci(curScintilla, SCI_SETSELECTIONEND, (intptr_t)allTextLength, 0);
            selBuf.assign(allTextLength + 1, 0);
        } else {
            selBuf.assign(asciiTextLen + 1, 0);
        }
        sci(curScintilla, SCI_GETSELTEXT, 0, (intptr_t)selBuf.data());

        // ── request parsing (verbatim from PluginDefinition.cpp::MakeRestCall) ──
        std::array<string, 7> restVerbs = { "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" };
        string s(selBuf.data());
        string eol("\r\n");
        string headerSeparator(":");
        string portSeparator(":");
        string slashSeparator("/");
        string varStartTag("$(");
        string varEndTag(")");
        string envTag("ENV:");
        string domain;
        string path;
        string verb;
        string url;
        string headerName;
        string headerValue;
        string body;
        string response;
        const string httpProtocol("http://");
        const string httpsProtocol("https://");
        bool firstLine = true;
        bool workingOnHeaders = false;
        bool workingOnBody = false;
        bool workingOnOptions = false;
        bool httpsProtocolFound = false;
        bool showResponseHeaders = false;
        bool showResponseOnSamePage = false;
        std::map<string, string> headers;
        size_t slashIndex = 0;
        int port = 0;

        // strtok_s over CR/LF, exactly like the Windows source (note: this treats
        // \r and \n each as a delimiter, so blank lines are skipped — matched).
        std::vector<char> tokBuf(s.begin(), s.end());
        tokBuf.push_back('\0');
        char *nextToken = nullptr;
        char *token = ::strtok_r(tokBuf.data(), eol.c_str(), &nextToken);

        while (token != nullptr) {
            string strToken(token);

            LTrim(&strToken);

            string tmpTokenUpper = strToken;
            ToUpper(&tmpTokenUpper);

            // Section markers.
            if (!firstLine && tmpTokenUpper.find("**HEADERS**", 0) != string::npos) {
                workingOnHeaders = true; workingOnBody = false; workingOnOptions = false;
                token = ::strtok_r(nullptr, eol.c_str(), &nextToken);
                continue;
            } else if (!firstLine && tmpTokenUpper.find("**BODY**", 0) != string::npos) {
                workingOnBody = true; workingOnHeaders = false; workingOnOptions = false;
                token = ::strtok_r(nullptr, eol.c_str(), &nextToken);
                continue;
            } else if (!firstLine && tmpTokenUpper.find("**RESTAPITOTEXTOPTIONS**", 0) != string::npos) {
                workingOnOptions = true; workingOnBody = false; workingOnHeaders = false;
                token = ::strtok_r(nullptr, eol.c_str(), &nextToken);
                continue;
            }

            if (firstLine) {
                firstLine = false;

                size_t index = strToken.find_first_of(" \t", 0);
                if (index != string::npos && index > 0) {
                    verb = strToken.substr(0, index);
                    ToUpper(&verb);

                    if (!std::any_of(restVerbs.begin(), restVerbs.end(),
                                     [verb](string v) { return v == verb; })) {
                        verb = "GET";
                        index = 0;
                    }

                    strToken = strToken.substr(index);
                    LTrim(&strToken);

                    string tmpToken = strToken;
                    InjectEnvironmentVars(tmpToken, varStartTag, varEndTag, envTag, url);

                    if (strToken.find(httpProtocol) != string::npos) {
                        url = url.substr(httpProtocol.length());
                        port = 80;   // INTERNET_DEFAULT_HTTP_PORT
                    } else if (strToken.find(httpsProtocol) != string::npos) {
                        httpsProtocolFound = true;
                        url = url.substr(httpsProtocol.length());
                        port = 443;  // INTERNET_DEFAULT_HTTPS_PORT
                    }

                    size_t portIndex = url.find(portSeparator.c_str());
                    if (portIndex != string::npos) {
                        string portString = url.substr(portIndex + 1, url.length());
                        port = atoi(portString.c_str());
                        domain = url.substr(0, portIndex);
                        slashIndex = portString.find(slashSeparator.c_str());
                        if (slashIndex != string::npos)
                            path = portString.substr(slashIndex, portString.length());
                    } else {
                        slashIndex = url.find(slashSeparator.c_str());
                        domain = url.substr(0, slashIndex);
                        if (slashIndex != string::npos)
                            path = url.substr(slashIndex, url.length());
                    }
                }
            } else {
                if (workingOnHeaders) {
                    LTrim(&strToken);
                    size_t headerIndex = strToken.find_first_of(headerSeparator.c_str(), 0);
                    if (headerIndex != string::npos) {
                        headerName = strToken.substr(0, headerIndex);
                        strToken = strToken.substr(headerIndex + 1);
                        LTrim(&strToken);
                        headerValue = strToken;

                        string tmpHeaderValue = headerValue;
                        ToUpper(&tmpHeaderValue);

                        if ((tmpHeaderValue.length() > varStartTag.length() + varEndTag.length()) &&
                            tmpHeaderValue.find(varStartTag.c_str(), 0) == 0 &&
                            EndsWith(tmpHeaderValue, varEndTag)) {
                            string hv = tmpHeaderValue.substr(
                                varStartTag.length(),
                                tmpHeaderValue.length() - (varStartTag.length() + varEndTag.length()));
                            size_t tagPos = hv.find(":", 0);
                            if (tagPos != string::npos && tagPos > 0) {
                                string tag = hv.substr(0, tagPos + 1);
                                ToUpper(&tag);
                                if (tag == envTag) {
                                    if (!GetEnvironmentVar(hv, envTag, headerValue)) {
                                        string missing = hv.substr(envTag.length());
                                        string errorMessage =
                                            "Could not find environment variable \"" + missing +
                                            "\".  If Nextpad++ was running when you created the "
                                            "variable, try closing and reopening it.";
                                        showAlert("RestApiToText", errorMessage.c_str());
                                    }
                                }
                            }
                        }

                        headers.insert(std::pair<string, string>(headerName, headerValue));
                    }
                } else if (workingOnBody) {
                    string tmpToken = strToken;
                    InjectEnvironmentVars(tmpToken, varStartTag, varEndTag, envTag, body);
                } else if (workingOnOptions) {
                    LTrim(&strToken);
                    ToUpper(&strToken);
                    if (strToken == "SHOWRESPONSEHEADERS")    showResponseHeaders   = true;
                    if (strToken == "SHOWRESPONSEONSAMEPAGE") showResponseOnSamePage = true;
                }
            }

            token = ::strtok_r(nullptr, eol.c_str(), &nextToken);
        }

        if (httpsProtocolFound && port == 0)
            port = 443;

        bool secure = httpsProtocolFound || port == 443;

        // ── transport (NSURLSession instead of WinINet) ──
        HttpResult http = performHttpRequest(verb, domain, port, path, secure, headers, body);

        if (http.transportError) {
            response = http.transportErrorText;
        } else if (verb == "HEAD" || verb == "OPTIONS") {
            response = http.rawHeaders;
        } else {
            string err = CheckForError(http);
            if (!err.empty()) response = err;

            response += http.body;

            bool contentTypeIsJson = false;
            {
                string ct = http.contentType;
                std::transform(ct.begin(), ct.end(), ct.begin(),
                               [](unsigned char c) { return (char)std::tolower(c); });
                // Windows treats a missing Content-Type header as JSON=TRUE.
                contentTypeIsJson = http.contentType.empty()
                                    ? true
                                    : (ct.find("application/json") != string::npos);
            }
            if (contentTypeIsJson)
                response = FormatResponseIntoJson(response);

            if (showResponseHeaders)
                response = http.rawHeaders + "\n\n" + response;
        }

        // ── write the response back into the editor ──
        if (!showResponseOnSamePage) {
            nppData._sendMessage(nppData._nppHandle, NPPM_MENUCOMMAND, 0, 41001 /* IDM_FILE_NEW */);
            end = 0;
        }

        // Re-resolve: a new tab may have switched the active Scintilla.
        curScintilla = currentScintilla();
        if (!curScintilla) return;

        sci(curScintilla, SCI_INSERTTEXT, (uintptr_t)end, (intptr_t)response.c_str());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  About / Help dialogs — programmatic AppKit, modal (replace the Win32 DIALOGs)
// ─────────────────────────────────────────────────────────────────────────────
@interface RA2TDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@end

@implementation RA2TDialogController

- (NSTextField *)label:(NSString *)s frame:(NSRect)f to:(NSView *)v {
    NSTextField *t = [NSTextField labelWithString:s];
    t.frame = f;
    [v addSubview:t];
    return t;
}

- (NSTextField *)wrappingLabel:(NSString *)s frame:(NSRect)f to:(NSView *)v {
    NSTextField *t = [NSTextField wrappingLabelWithString:s];
    t.frame = f;
    t.selectable = NO;
    t.maximumNumberOfLines = 0;
    [v addSubview:t];
    return t;
}

// Clickable hyperlink rendered as a borderless button.
- (void)link:(NSString *)urlStr at:(NSRect)f to:(NSView *)v {
    NSButton *b = [NSButton buttonWithTitle:urlStr target:self action:@selector(openLink:)];
    b.bordered = NO;
    b.bezelStyle = NSBezelStyleInline;
    b.frame = f;
    b.contentTintColor = [NSColor linkColor];
    b.alignment = NSTextAlignmentLeft;
    [[b cell] setIdentifier:urlStr];
    b.identifier = urlStr;
    b.toolTip = urlStr;
    [v addSubview:b];
}

- (void)openLink:(NSButton *)sender {
    NSURL *u = [NSURL URLWithString:sender.identifier];
    if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

- (void)ok:(id)sender { [NSApp stopModal]; }
- (void)windowWillClose:(NSNotification *)n { [NSApp stopModal]; }

- (void)runModal {
    [self.window center];
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];
}

// Build the About window (mirrors IDD_RESTAPITOTEXT).
+ (RA2TDialogController *)about {
    RA2TDialogController *c = [[RA2TDialogController alloc] init];
    const CGFloat W = 540, H = 220;
    c.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                           styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    c.window.title = @"REST API To Text";
    c.window.delegate = c;
    c.window.releasedWhenClosed = NO;
    NSView *root = c.window.contentView;

    CGFloat y = H - 44;
    const CGFloat labelX = 20, valueX = 110, rowH = 22;

    [c label:@"Author:"  frame:NSMakeRect(labelX, y, 80, 18) to:root];
    [c label:@"Jeffrey Smith <jeffdsmith3@gmail.com>" frame:NSMakeRect(valueX, y, W - valueX - 20, 18) to:root];
    y -= rowH;
    [c label:@"License:" frame:NSMakeRect(labelX, y, 80, 18) to:root];
    [c label:@"GNU GPL v3" frame:NSMakeRect(valueX, y, W - valueX - 20, 18) to:root];
    y -= rowH;
    [c label:@"Version:" frame:NSMakeRect(labelX, y, 80, 18) to:root];
    [c label:@"1.4.0.1 (macOS port)" frame:NSMakeRect(valueX, y, W - valueX - 20, 18) to:root];
    y -= rowH;
    [c label:@"Project:" frame:NSMakeRect(labelX, y, 80, 18) to:root];
    [c link:@"https://github.com/eljefe7000/RestApiToText"
          at:NSMakeRect(valueX - 2, y, W - valueX - 20, 18) to:root];
    y -= rowH;
    [c label:@"Plugin News:" frame:NSMakeRect(labelX, y, 90, 18) to:root];
    [c link:@"https://community.notepad-plus-plus.org/category/5/plugin-development"
          at:NSMakeRect(valueX - 2, y, W - valueX - 20, 18) to:root];

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:c action:@selector(ok:)];
    ok.frame = NSMakeRect(W - 98, 16, 80, 30);
    ok.keyEquivalent = @"\r";
    [root addSubview:ok];
    return c;
}

// Build the Help window (mirrors IDD_HELP).
+ (RA2TDialogController *)help {
    RA2TDialogController *c = [[RA2TDialogController alloc] init];
    const CGFloat W = 600, H = 470;
    c.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                           styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    c.window.title = @"REST API To Text Help";
    c.window.delegate = c;
    c.window.releasedWhenClosed = NO;
    NSView *root = c.window.contentView;

    NSString *helpText =
        @"Make a REST API call and get the results in a new Nextpad++ tab.\n\n"
        @"Here is how it works:\n\n"
        @"1.  At the start of a line, type in the elements of a REST call.  Put each "
        @"header on its own line.\n\n"
        @"      GET http://localhost:12345/weatherforecast\n"
        @"      **Headers**\n"
        @"      Content-Type: application/json\n"
        @"      X-Api-Key: 1234\n"
        @"      **RestApiToTextOptions**\n"
        @"      ShowResponseHeaders\n\n"
        @"   (The **Headers** line tells RestApiToText that you have headers to send.)\n\n"
        @"2.  Under the Plugins menu, pick \"REST API To Text\" then \"Make REST Call\".\n\n"
        @"3.  A new tab containing the results of the REST call should appear.\n\n"
        @"Options available for **RestApiToTextOptions**:\n"
        @"   • ShowResponseHeaders     — Show response headers in the REST response.\n"
        @"   • ShowResponseOnSamePage  — Show the response after the REST call, on the same page.\n\n"
        @"Notes:\n"
        @"   • If the page has content besides the REST call, select the REST content before "
        @"making the call.\n"
        @"   • Prepending the URL with http:// or https:// is optional, as is the port.\n"
        @"   • To add a body for a POST/PUT, add a **Body** line, then the body.\n"
        @"   • Calls to regular web pages should also work and return the HTML markup.\n"
        @"   • To keep an API key private, create an environment variable and reference it like so "
        @"(works in the URI, querystring, headers and body):\n"
        @"        X-Api-Key: $(env:YOUR-ENVIRONMENT-VARIABLE-NAME-HERE)\n"
        @"   • For more info on usage and new releases, click the project link in the About window.";

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 56, W - 32, H - 72)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    tv.editable = NO;
    tv.drawsBackground = YES;
    tv.string = helpText;
    tv.font = [NSFont systemFontOfSize:12];
    tv.textContainerInset = NSMakeSize(8, 8);
    tv.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = tv;
    [root addSubview:scroll];

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:c action:@selector(ok:)];
    ok.frame = NSMakeRect(W - 98, 14, 80, 30);
    ok.keyEquivalent = @"\r";
    [root addSubview:ok];
    return c;
}
@end

static void AboutDialog() {
    @autoreleasepool { [[RA2TDialogController about] runModal]; }
}

static void HelpDialog() {
    @autoreleasepool { [[RA2TDialogController help] runModal]; }
}

// ── plugin exports ───────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;

    memset(funcItem, 0, sizeof(funcItem));
    strncpy(funcItem[0]._itemName, "Make REST Call", NPP_MENU_ITEM_SIZE - 1);
    funcItem[0]._pFunc  = MakeRestCall;
    funcItem[0]._pShKey = nullptr;   // Windows used Ctrl+Alt+A; host ignores plugin shortcuts.

    strncpy(funcItem[1]._itemName, "About...", NPP_MENU_ITEM_SIZE - 1);
    funcItem[1]._pFunc  = AboutDialog;
    funcItem[1]._pShKey = nullptr;

    strncpy(funcItem[2]._itemName, "Help...", NPP_MENU_ITEM_SIZE - 1);
    funcItem[2]._pFunc  = HelpDialog;
    funcItem[2]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = nbFunc; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    (void)n;   // No toolbar icon and nothing to clean up on shutdown.
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l;
    return 1;
}
