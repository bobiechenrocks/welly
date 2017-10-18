//
//  WLPTY.m
//  Welly
//
//  Created by boost @ 9# on 7/13/08.
//  Copyright 2008 Xi Wang. All rights reserved.

//  YLSSH.m
//  MacBlueTelnet
//
//  Created by Lan Yung-Luen on 12/7/07.
//  Copyright 2007 yllan.org. All rights reserved.
//

/* Code from iTerm : PTYTask.m */

#include <util.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <termios.h>
#include <stdlib.h>
#import "WLGlobalConfig.h"
#import "WLPTY.h"
#import "WLProxy.h"

#define CTRLKEY(c)   ((c)-'A'+1)

@implementation WLPTY
@synthesize delegate = _delegate;
@synthesize proxyType = _proxyType;
@synthesize proxyAddress = _proxyAddress;

+ (NSString *)parse:(NSString *)addr {
    // trim whitespaces
    addr = [addr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // command, not "URL"
    if ([addr rangeOfString:@" "].length > 0)
        return addr;
    // check protocol
    BOOL ssh, websock;
    NSString *port = nil;
    NSRange range;
    if ([[addr lowercaseString] hasPrefix: @"ssh://"]) {
        ssh = YES;
        websock = NO;
        addr = [addr substringFromIndex:6];
    } else if ([[addr lowercaseString] hasPrefix: @"wss://"]) {
        websock = YES;
        ssh = NO;
        addr = [addr substringFromIndex:6];
    }else {
        ssh = NO;
        websock = NO;
        range = [addr rangeOfString:@"://"];
        if (range.length > 0)
            addr = [addr substringFromIndex:range.location + range.length];
    }
    // check port
    range = [addr rangeOfString:@":"];
    if (range.length > 0) {
        port = [addr substringFromIndex:range.location + range.length];
        addr = [addr substringToIndex:range.location];
    }
    // make the command
    NSString *fmt, *proxyScript;
    if (ssh) {
        if (port == nil)
            port = @"22";
        range = [addr rangeOfString:@"@"];
        // remove username for telnet
        if (range.length > 0)
            addr = [addr substringFromIndex:range.location + range.length];
        fmt = @"/usr/bin/ssh -4 -o PubkeyAuthentication=no -o Protocol=2,1 -p %2$@ -x bbs@%1$@";
    } else if (websock) {
        port = [NSString stringWithFormat:@"%d", arc4random_uniform(99999)];
        proxyScript = [[NSBundle mainBundle] pathForResource:@"proxy.sh" ofType:@""];
        range = [addr rangeOfString:@"@"];
        // remove username for telnet
        if (range.length > 0)
            addr = [addr substringFromIndex:range.location + range.length];
    } else {
        if (port == nil)
            port = @"23";
        range = [addr rangeOfString:@"@"];
        // remove username for telnet
        if (range.length > 0)
            addr = [addr substringFromIndex:range.location + range.length];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:@"/usr/bin/telnet"]) {
            NSString *filePath = [[NSBundle mainBundle] pathForResource:@"telnet" ofType:@""];
            fmt = [NSString stringWithFormat:@"%@%@", filePath, @" -4 -8 %@ -%@"];
        } else {
            // "-" before the port number forces the initial option negotiation
            fmt = @"/usr/bin/telnet -4 -8 %@ -%@";
        }
    }
    
    NSString *r;
    if (websock) {
        // only needs to escape the command path
        //proxyScript = [NSRegularExpression escapedPatternForString:proxyScript];
        r = [NSString stringWithFormat:@"%@ wss://%@ %@", proxyScript, addr, port];
    } else {
        r = [NSString stringWithFormat:fmt, addr, port];
    }
    
    // before return the cmd, we need to take care of strange directory name issue
    // eg:   "/some/where/app/store/a   b/Welly.app"
    int bundleCmdPos = 0;
    if( (bundleCmdPos = [r rangeOfString:@".app/Contents/Resources/proxy.sh"].location) > 0 || (bundleCmdPos = [r rangeOfString:@".app/Contents/Resources/telnet"].location) > 0 ){
        NSError *error = nil;
        NSString *charNeedEsc = @"[\\^\"\!@\\$&\*\(\)'<\ >,\?\\\\]";
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:charNeedEsc options:nil error:&error];
        NSString *baseDir = [r substringToIndex:bundleCmdPos];
        NSString *cleanBaseDir = [regex stringByReplacingMatchesInString:baseDir
                                                                 options:0
                                                                   range:NSMakeRange(0, [baseDir length])
                                                            withTemplate:@"\\\\$0"];
        NSString *restCmd = [r substringFromIndex:bundleCmdPos];
        
        r = [NSString stringWithFormat:@"%@%@", cleanBaseDir, restCmd];
    }
    return r;
}

+ (void) logConsole: (NSString *) msg {
    NSError *error = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0]; // Get documents directory
    
    [[NSString stringWithFormat:@"%@\n", msg] writeToFile:[documentsDirectory stringByAppendingPathComponent:@"myfile.txt"]
                                                                       atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
}

- (id)init {
    if (self == [super init]) {
        _pid = 0;
        _fd = -1;
    }
    return self;
}

- (void)dealloc {
    [self close];
    [super dealloc];
}

- (void)close {
    if (_pid > 0) {
        kill(_pid, SIGKILL);
        _pid = 0;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
        [_delegate protocolDidClose:self];
    }
}

- (BOOL)connect:(NSString *)addr {
    char slaveName[PATH_MAX];
    struct termios term;
    struct winsize size;
    
    term.c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
    term.c_oflag = OPOST | ONLCR;
    term.c_cflag = CREAD | CS8 | HUPCL;
    term.c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
    
    term.c_cc[VEOF]      = CTRLKEY('D');
    term.c_cc[VEOL]      = -1;
    term.c_cc[VEOL2]     = -1;
    term.c_cc[VERASE]    = 0x7f;	// DEL
    term.c_cc[VWERASE]   = CTRLKEY('W');
    term.c_cc[VKILL]     = CTRLKEY('U');
    term.c_cc[VREPRINT]  = CTRLKEY('R');
    term.c_cc[VINTR]     = CTRLKEY('C');
    term.c_cc[VQUIT]     = 0x1c;	// Control+backslash
    term.c_cc[VSUSP]     = CTRLKEY('Z');
    term.c_cc[VDSUSP]    = CTRLKEY('Y');
    term.c_cc[VSTART]    = CTRLKEY('Q');
    term.c_cc[VSTOP]     = CTRLKEY('S');
    term.c_cc[VLNEXT]    = -1;
    term.c_cc[VDISCARD]  = -1;
    term.c_cc[VMIN]      = 1;
    term.c_cc[VTIME]     = 0;
    term.c_cc[VSTATUS]   = -1;
    
    term.c_ispeed = B38400;
    term.c_ospeed = B38400;
    size.ws_col = [[WLGlobalConfig sharedInstance] column];
    size.ws_row = [[WLGlobalConfig sharedInstance] row];
    size.ws_xpixel = 0;
    size.ws_ypixel = 0;
    
    _pid = forkpty(&_fd, slaveName, &term, &size);
    if (_pid == 0) { /* child */
        NSArray *a = [[WLPTY parse:addr] componentsSeparatedByString:@" "];
        if ([(NSString *)[a objectAtIndex:0] hasSuffix:@"ssh"]) {
            NSString *proxyCommand = [WLProxy proxyCommandWithAddress:_proxyAddress type:_proxyType];
            if (proxyCommand) {
                a = [[a arrayByAddingObject:@"-o"] arrayByAddingObject:proxyCommand];
            }
            
            int n = [a count];
            char *argv[n+1];
            for (int i = 0; i < n; ++i){
                argv[i] = (char *)[[a objectAtIndex:i] UTF8String];
            }
            argv[n] = NULL;
            execvp(argv[0], argv);
            perror(argv[0]);
            sleep(-1); // don't bother
        } else {
            char *argv[4];
            argv[0] = (char *)[@"/bin/sh" UTF8String];
            argv[1] = (char *)[@"-c"  UTF8String];
            argv[2] = (char *)[[WLPTY parse:addr] UTF8String];
            argv[3] = NULL;
            execvp(argv[0], argv);
            perror(argv[0]);
            sleep(-1); // don't bother
            
        }
    } else { /* parent */
        int one = 1;
        ioctl(_fd, TIOCPKT, &one);
        [self retain]; // for the thread
        [NSThread detachNewThreadSelector:@selector(readLoop:) toTarget:[self class] withObject:self];
    }
    
    _connecting = YES;
    [_delegate protocolWillConnect:self];
    return YES;
}

- (void)recv:(NSData *)data {
    if (_connecting) {
        _connecting = NO;
        [_delegate protocolDidConnect:self];
    }
    [_delegate protocolDidRecv:self data:data];
    [data autorelease]; // allocated in the read loop
}

- (void)send:(NSData *)data {
    fd_set writefds, errorfds;
    struct timeval timeout;
    int chunkSize;
    
    if (_fd < 0 || _connecting) // disable input when connecting
        return;
    
    [_delegate protocolWillSend:self data:data];
    
    const char *msg = [data bytes];
    int length = [data length];
    while (length > 0) {
        FD_ZERO(&writefds);
        FD_ZERO(&errorfds);
        FD_SET(_fd, &writefds);
        FD_SET(_fd, &errorfds);
        
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;
        
        int result = select(_fd + 1, NULL, &writefds, &errorfds, &timeout);
        
        if (result == 0) {
            NSLog(@"timeout!");
            break;
        } else if (result < 0) { // error
            [self close];
            break;
        }
        
        if (length > 4096) chunkSize = 4096;
        else chunkSize = length;
        
        int size = write(_fd, msg, chunkSize);
        if (size < 0)
            break;
        
        msg += size;
        length -= size;
    }
}

// NOTE: retain pty before starting the thread
+ (void)readLoop:(WLPTY *)pty {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    fd_set readfds, errorfds;
    BOOL exit = NO;
    unsigned char buf[4096];
    int iterationCount = 0;
    int result;
    
    while (!exit) {
        iterationCount++;
        
        FD_ZERO(&readfds);
        FD_ZERO(&errorfds);
        
        FD_SET(pty->_fd, &readfds);
        FD_SET(pty->_fd, &errorfds);
        
        result = select(pty->_fd + 1, &readfds, NULL, &errorfds, NULL);
        
        if (result < 0) {       // error
            break;
        } else if (FD_ISSET(pty->_fd, &errorfds)) {
            result = read(pty->_fd, buf, 1);
            if (result == 0) {  // session close
                exit = YES;
            }
        } else if (FD_ISSET(pty->_fd, &readfds)) {
            result = read(pty->_fd, buf, sizeof(buf));
            if (result > 1) {
                [pty performSelectorOnMainThread:@selector(recv:)
                                      withObject:[[NSData alloc] initWithBytes:buf+1 length:result-1]
                                   waitUntilDone:NO];
            }
            if (result == 0) {
                exit = YES;
            }
        }
        
        if (iterationCount % 5000 == 0) {
            [pool release];
            pool = [NSAutoreleasePool new];
            iterationCount = 1;
        }
    }
    
    if (result >= 0) {
        [pty performSelectorOnMainThread:@selector(close) withObject:nil waitUntilDone:NO];
    }
    
    [pool release];
    [pty release];
    [NSThread exit];
}
@end
