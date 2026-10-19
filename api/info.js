export default function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  // Vercel has no knowledge of the local game/relay — return neutral defaults
  // so the browser still calls connect() and tries ws://localhost:8765
  res.status(200).json({
    local_ip: "127.0.0.1",
    relay_port: 8765,
    game_running: false,
    game_found: false,
    explorer_done: false,
    install_status: "not_needed",
    my_mods: [],
    pak_mods: [],
    join_mode: false,
    bridge: false,
  });
}
