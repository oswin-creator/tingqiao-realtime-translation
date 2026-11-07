from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import time,pathlib,sys
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  unknown=self.path.startswith('/unknown');length=2*1024*1024
  self.send_response(200)
  if not unknown:self.send_header('Content-Length',str(length))
  self.send_header('Content-Type','application/octet-stream');self.end_headers()
  try:
   for _ in range(length//16384):self.wfile.write(b'x'*16384);self.wfile.flush();time.sleep(.008)
  except (BrokenPipeError,ConnectionResetError):pass
s=ThreadingHTTPServer(('127.0.0.1',0),Handler)
pathlib.Path(sys.argv[1]).write_text(str(s.server_port))
s.serve_forever()
