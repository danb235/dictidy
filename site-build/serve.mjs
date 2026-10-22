import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../site');
const mime={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.xml':'application/xml','.txt':'text/plain'};
const headers=Object.fromEntries(fs.readFileSync(path.join(root,'_headers'),'utf8').split('\n').filter(l=>/^  [\w-]+:/.test(l)).map(l=>{const i=l.indexOf(':');return [l.slice(0,i).trim(),l.slice(i+1).trim()]}));
const server=http.createServer((req,res)=>{
  let requested;
  try { requested=decodeURIComponent(new URL(req.url,'http://localhost').pathname); } catch {res.writeHead(400);res.end('Bad request');return;}
  let file=path.resolve(root,'.'+requested),status=200;
  if(requested==='/') file=path.join(root,'index.html');
  else if(!path.extname(file)) file+='.html';
  if(!file.startsWith(root+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile()){file=path.join(root,'404.html');status=404;}
  res.writeHead(status,{...headers,'Content-Type':mime[path.extname(file)]||'application/octet-stream'});
  fs.createReadStream(file).pipe(res);
});
const port=Number(process.env.DICTIDY_PREVIEW_PORT || 4173);
server.listen(port,'127.0.0.1',()=>console.log(`Dictidy preview: http://127.0.0.1:${port}`));
