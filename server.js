// NOVA Dashboard Server - Express + WebSocket for real-time updates
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');
const chokidar = require('chokidar');

const PORT = process.env.PORT || 3847;
const DATA_DIR = '/home/nova/www/static/dashboard';

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Serve static files from public directory, fallback to root
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.static(__dirname));

// Track connected clients
let clientCount = 0;

wss.on('connection', (ws) => {
  clientCount++;
  console.log(`📡 Client connected (${clientCount} total)`);
  
  // Send initial data
  sendData(ws);
  
  ws.on('close', () => {
    clientCount--;
    console.log(`📡 Client disconnected (${clientCount} total)`);
  });
});

// Read and send JSON data
function sendData(ws) {
  try {
    const status = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'status.json'), 'utf8'));
    const system = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'system.json'), 'utf8'));
    const anthropic = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'anthropic.json'), 'utf8'));
    
    ws.send(JSON.stringify({ type: 'update', status, system, anthropic }));
  } catch (err) {
    console.error('Error reading data:', err.message);
  }
}

// Broadcast to all clients
function broadcast() {
  wss.clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      sendData(client);
    }
  });
}

// Watch for file changes and broadcast updates
const watcher = chokidar.watch([
  path.join(DATA_DIR, 'status.json'),
  path.join(DATA_DIR, 'system.json'),
  path.join(DATA_DIR, 'anthropic.json')
], { ignoreInitial: true });

watcher.on('change', (filepath) => {
  console.log(`📄 File changed: ${path.basename(filepath)}`);
  broadcast();
});

server.listen(PORT, () => {
  console.log(`🚀 NOVA Dashboard server running on port ${PORT}`);
  console.log(`📁 Serving from: ${__dirname}`);
  console.log(`📊 Data from: ${DATA_DIR}`);
});
