const { cookieHeader } = require("./_session");

module.exports = function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Set-Cookie", cookieHeader("", 0));
  res.writeHead(302, { Location: "/login.html" });
  res.end();
};
