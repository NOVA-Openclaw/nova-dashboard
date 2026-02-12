// NOVA Dashboard Server - Express + WebSocket for real-time updates
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');
const chokidar = require('chokidar');
const { exec } = require('child_process');

const PORT = process.env.PORT || 3847;
const DATA_DIR = '/home/nova/www/static/dashboard';

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Serve JSON data files from the data directory
app.get('/status.json', (req, res) => res.sendFile(path.join(DATA_DIR, 'status.json')));
app.get('/anthropic.json', (req, res) => res.sendFile(path.join(DATA_DIR, 'anthropic.json')));
app.get('/system.json', (req, res) => res.sendFile(path.join(DATA_DIR, 'system.json')));
app.get('/staff.json', (req, res) => res.sendFile(path.join(DATA_DIR, 'staff.json')));

// Get top resource-consuming processes
app.get('/processes.json', async (req, res) => {
  try {
    const sortBy = req.query.sortBy || 'cpu'; // 'cpu' or 'memory'
    const limit = parseInt(req.query.limit) || 5;
    
    const processes = await getTopProcesses(sortBy, limit);
    
    res.json({
      processes,
      sortBy,
      limit,
      updated: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error fetching processes:', error);
    res.status(500).json({
      error: 'Failed to fetch process data',
      message: error.message,
      processes: [],
      updated: new Date().toISOString()
    });
  }
});

// Serve static files from public directory, fallback to root
// Removed public/ - serve from root only
app.use(express.static(__dirname));

// Function to get top processes by CPU or memory
async function getTopProcesses(sortBy = 'cpu', limit = 5) {
  return new Promise((resolve, reject) => {
    // Use ps command to get process information
    // Sort by CPU% or MEM% depending on sortBy parameter
    const sortFlag = sortBy === 'memory' ? '-%mem' : '-%cpu';
    const command = `ps aux --sort=${sortFlag} | head -n ${limit + 1}`;
    
    exec(command, (error, stdout, stderr) => {
      if (error) {
        console.error('ps command error:', error);
        return reject(new Error(`ps command failed: ${error.message}`));
      }
      
      if (stderr) {
        console.warn('ps command stderr:', stderr);
      }
      
      try {
        const lines = stdout.trim().split('\n');
        if (lines.length < 2) {
          return resolve([]);
        }
        
        // Skip header line (first line)
        const processLines = lines.slice(1);
        
        const processes = processLines.map(line => {
          // Parse ps aux output format:
          // USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
          const parts = line.trim().split(/\s+/);
          
          if (parts.length < 11) {
            return null; // Skip malformed lines
          }
          
          const user = parts[0];
          const pid = parts[1];
          const cpu = parseFloat(parts[2]) || 0;
          const mem = parseFloat(parts[3]) || 0;
          // Command is everything from index 10 onwards
          const command = parts.slice(10).join(' ');
          
          // Truncate long command names
          const maxCommandLength = 100;
          const truncatedCommand = command.length > maxCommandLength 
            ? command.substring(0, maxCommandLength) + '...' 
            : command;
          
          return {
            pid,
            user,
            cpu: cpu.toFixed(1),
            memory: mem.toFixed(1),
            command: truncatedCommand
          };
        }).filter(p => p !== null); // Remove null entries
        
        resolve(processes);
      } catch (parseError) {
        console.error('Error parsing ps output:', parseError);
        reject(new Error(`Failed to parse process data: ${parseError.message}`));
      }
    });
  });
}

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
    let staff = {};
    try {
      staff = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'staff.json'), 'utf8'));
    } catch (e) { /* staff.json may not exist yet */ }
    
    ws.send(JSON.stringify({ type: 'update', status, system, anthropic, staff }));
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
  path.join(DATA_DIR, 'anthropic.json'),
  path.join(DATA_DIR, 'staff.json')
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
