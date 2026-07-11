import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class IsolatedRequestHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    handler = partial(IsolatedRequestHandler, directory=args.directory)
    ThreadingHTTPServer(("", args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
