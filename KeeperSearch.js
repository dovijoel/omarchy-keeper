.pragma library

// Pure search helpers for the Keeper overlay. Records come from the cached
// index (uid, title, login, url, host) and never contain secrets.

function normalize(text) {
  return String(text || "").toLowerCase()
}

function parseIndex(raw) {
  var list = []
  try {
    var parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return list
    for (var i = 0; i < parsed.length; i++) {
      var r = parsed[i]
      if (!r || !r.record_uid) continue
      var title = String(r.title || "")
      var login = String(r.login || "")
      var url = String(r.url || "")
      var host = String(r.host || "")
      list.push({
        uid: String(r.record_uid),
        title: title || "(untitled)",
        login: login,
        url: url,
        host: host,
        type: String(r.type || ""),
        subtext: [login, host].filter(function(x) { return x }).join(" · "),
        _title: normalize(title),
        _login: normalize(login),
        _host: normalize(host),
        _url: normalize(url)
      })
    }
  } catch (e) {
    return list
  }
  list.sort(function(a, b) { return a._title < b._title ? -1 : a._title > b._title ? 1 : 0 })
  return list
}

// Every whitespace-separated word must match the title, login, host or URL.
// Score favours title prefix > title word start > title substring > login >
// host > url, then shorter titles, so "22seven" lists the site itself first
// and "dovi@joel.family 22seven" narrows to that account.
function scoreRecord(rec, words) {
  var total = 0
  for (var w = 0; w < words.length; w++) {
    var word = words[w]
    var best = 0
    if (rec._title.indexOf(word) === 0) best = 60
    else if (rec._title.indexOf(" " + word) >= 0 || rec._title.indexOf("." + word) >= 0) best = 50
    else if (rec._title.indexOf(word) >= 0) best = 40
    if (best < 45 && rec._login.indexOf(word) >= 0) best = Math.max(best, rec._login.indexOf(word) === 0 ? 45 : 30)
    if (best < 35 && rec._host.indexOf(word) >= 0) best = Math.max(best, rec._host.indexOf(word) === 0 ? 35 : 25)
    if (best === 0 && rec._url.indexOf(word) >= 0) best = 10
    if (best === 0) return -1
    total += best
  }
  return total - Math.min(rec._title.length, 40) / 100
}

function filterRecords(records, query, limit) {
  var words = normalize(query).split(/\s+/).filter(function(x) { return x })
  if (words.length === 0) return records.slice(0, limit)
  var scored = []
  for (var i = 0; i < records.length; i++) {
    var s = scoreRecord(records[i], words)
    if (s >= 0) scored.push({ rec: records[i], score: s })
  }
  scored.sort(function(a, b) { return b.score - a.score })
  var out = []
  for (var j = 0; j < scored.length && j < limit; j++) out.push(scored[j].rec)
  return out
}

function findByUid(records, uid) {
  for (var i = 0; i < records.length; i++) if (records[i].uid === uid) return records[i]
  return null
}
