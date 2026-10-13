const http = require('http');
const os = require('os');
const port = process.env.PORT || 3000;

http.createServer((req, res) => {
  if (req.url === '/api/health') { res.end('ok'); return; }
  if (req.url === '/api/hello') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ msg: 'hello from the backend', pod: os.hostname(), now: new Date().toISOString() }));
    return;
  }
  res.statusCode = 404;
  res.end('not found');
}).listen(port, () => console.log('backend escuchando en ' + port));
