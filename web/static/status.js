// Refreshes the Status page every 5 seconds from /api/status.
(function () {
  "use strict";
  var root = document.getElementById("status");
  if (!root) return;
  var api = root.dataset.api;

  function $(id) { return document.getElementById(id); }
  function ago(iso) {
    var s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
    if (s < 90) return "just now";
    if (s < 5400) return Math.round(s / 60) + " min ago";
    if (s < 129600) return Math.round(s / 3600) + " h ago";
    return Math.round(s / 86400) + " days ago";
  }
  function bytes(n) {
    if (n == null) return "?";
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
    return (i ? n.toFixed(1) : n) + " " + u[i];
  }
  function when(epoch) {
    return new Date(epoch * 1000).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" });
  }

  function render(d) {
    $("sync-dot").className = "dot " + d.sync.level;
    $("sync-text").textContent = d.sync.text;
    var detail = d.who ? "Account: " + d.who : "";
    if (d.sync.row && d.sync.row.remote) detail += " · MEGA folder: " + d.sync.row.remote;
    $("sync-detail").textContent = detail;

    var e = d.engine || {};
    $("engine-text").textContent = d.backup_running ? "A backup is running now." : (e.message || "");

    var r = d.last_run;
    if (!r) {
      $("last-run").textContent = "No backup has run yet.";
    } else {
      var t = "Last backup: " + ago(r.finished) + ", ";
      if (r.result === "ok") t += "OK.";
      else if (r.result === "problems") t += "finished with problems: " + r.problems.join("; ");
      else t += "FAILED: " + r.problems.join("; ");
      if (r.diff) t += " Changes: " + r.diff.added + " added, " + r.diff.changed + " changed, " + r.diff.removed + " removed.";
      if (r.files_total != null) t += " " + r.files_total + " files, " + bytes(r.bytes_added) + " new data.";
      $("last-run").textContent = t;
      $("last-run").className = r.result === "ok" ? "" : "flash error";
    }
    $("next-run").textContent = e.next_backup ? "Next backup: " + when(e.next_backup) + "." : "";
    $("hold").hidden = !d.prune_hold;

    var parts = [];
    if (d.disk.current) parts.push("MEGA folder disk: " + bytes(d.disk.current.free) + " free of " + bytes(d.disk.current.total));
    if (d.disk.repo) parts.push("Backup folder disk: " + bytes(d.disk.repo.free) + " free of " + bytes(d.disk.repo.total));
    $("disk").textContent = parts.join(" · ");
  }

  function tick() {
    fetch(api, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) {
        if (r.status === 401) { location.reload(); throw new Error("logged out"); }
        return r.json();
      })
      .then(render)
      .catch(function () {})
      .finally(function () { setTimeout(tick, 5000); });
  }
  tick();
})();
