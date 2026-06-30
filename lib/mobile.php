<?php
/* Farooq Music — Mobile App API */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");

$USER_ID  = "226099197";
$FALLBACK = "9RxlC6NwiaJEj6SsGAJgmHYOYauqhn9E";
$CACHE    = sys_get_temp_dir() . "/fm_sc_client_id.txt";
$VCACHE   = sys_get_temp_dir() . "/fm_visuals_v2.json"; // track_id => wide visual URL
$VCACHE_TTL = 21600;                                   // refresh visuals every 6 hours

function hget($url, $t = 15) {
  if (function_exists('curl_init')) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true,CURLOPT_FOLLOWLOCATION=>true,
      CURLOPT_TIMEOUT=>$t,CURLOPT_SSL_VERIFYPEER=>true,
      CURLOPT_USERAGENT=>"Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0"]);
    $b = curl_exec($ch); curl_close($ch); return $b;
  }
  $ctx = stream_context_create(["http"=>["header"=>"User-Agent: Mozilla/5.0\r\n","timeout"=>$t]]);
  return @file_get_contents($url, false, $ctx);
}

function cid() {
  global $CACHE, $FALLBACK;
  if (is_file($CACHE) && (time()-filemtime($CACHE)<86400)) {
    $id = trim(file_get_contents($CACHE)); if ($id) return $id;
  }
  $html = hget("https://soundcloud.com/");
  if ($html) {
    preg_match_all('/<script[^>]+src="([^"]+)"/i', $html, $m);
    $n = 0;
    foreach (array_reverse($m[1]) as $s) {
      if (strpos($s,'sndcdn.com')===false) continue;
      if ($n++>12) break;
      $js = hget($s);
      if ($js && preg_match('/client_id\s*[:=]\s*"([a-zA-Z0-9_-]{20,})"/',$js,$mm)) {
        file_put_contents($CACHE,$mm[1]); return $mm[1];
      }
    }
  }
  return $FALLBACK;
}

/* Pull a labelled link out of a SoundCloud track description.
   Descriptions look like:  "... Explanation: www.reddit.com/...  Lyrics: www.reddit.com/...  YouTube: ..." */
function fm_link($desc, $label) {
  if (!$desc) return null;
  $re = '/' . preg_quote($label, '/') . '\s*:\s*(https?:\/\/\S+|www\.\S+)/i';
  if (preg_match($re, $desc, $m)) {
    $u = rtrim($m[1], " \t\r\n.,);\"'");
    if (stripos($u, 'http') !== 0) $u = 'https://' . $u;
    return $u;
  }
  return null;
}

/* Build one app-shaped track object from a raw SoundCloud track. */
function build_track($t) {
  $art = $t['artwork_url'] ?? ($t['user']['avatar_url'] ?? null);
  if ($art) $art = str_replace('-large','-t300x300',$art);

  /* Wide "visual" banner image (the cinematic header on the SoundCloud
     track page). It lives in the track's `visuals` object, separate from
     the square artwork. Null if the track has no visual set. */
  $banner = $t['visuals']['visuals'][0]['visual_url'] ?? null;

  $desc = $t['description'] ?? '';
  return [
    'id'          => (string)$t['id'],
    'title'       => $t['title'] ?? 'Unknown',
    'genre'       => $t['genre'] ?? '',
    'artwork'     => $art,
    'banner'      => $banner,
    'waveform'    => $t['waveform_url'] ?? null,
    'duration'    => (int)($t['duration'] ?? 0),
    'plays'       => (int)($t['playback_count'] ?? 0),
    'lyrics'      => fm_link($desc, 'Lyrics'),
    'explanation' => fm_link($desc, 'Explanation'),
  ];
}

/* Fetch every track for the user (paged), as app-shaped objects.
   $c is passed by reference so a refreshed client_id propagates back. */
function fetch_all_tracks(&$c) {
  global $USER_ID, $CACHE;
  $all = [];
  $next = "https://api-v2.soundcloud.com/users/{$USER_ID}/tracks?limit=50&access=playable&client_id={$c}";
  $pages = 0;
  while ($next && $pages < 5) {
    $body = hget($next);
    if (!$body) break;
    $data = json_decode($body, true);
    if (!$data || isset($data['error'])) {
      if (is_file($CACHE)) unlink($CACHE);
      $c = cid();
      $next = preg_replace('/client_id=[^&]+/', "client_id={$c}", $next);
      $body = hget($next);
      $data = json_decode($body, true);
      if (!$data) break;
    }
    foreach ($data['collection'] ?? [] as $t) {
      $all[] = build_track($t);
    }
    $next = $data['next_href'] ?? null;
    if ($next && strpos($next,'client_id')===false)
      $next .= "&client_id={$c}";
    $pages++;
  }
  return $all;
}

/* Fetch the user's albums (raw SoundCloud objects).
   Primary: dedicated /albums endpoint. Fallback: /playlists filtered to albums. */
function fetch_albums(&$c) {
  global $USER_ID, $CACHE;
  $out = [];

  // Primary — dedicated albums endpoint
  $next = "https://api-v2.soundcloud.com/users/{$USER_ID}/albums?limit=50&client_id={$c}";
  $pages = 0;
  while ($next && $pages < 5) {
    $body = hget($next);
    if (!$body) break;
    $data = json_decode($body, true);
    if (!$data || isset($data['error'])) {
      if (is_file($CACHE)) unlink($CACHE);
      $c = cid();
      $next = preg_replace('/client_id=[^&]+/', "client_id={$c}", $next);
      $body = hget($next);
      $data = json_decode($body, true);
      if (!$data) break;
    }
    foreach ($data['collection'] ?? [] as $p) {
      $out[] = $p;
    }
    $next = $data['next_href'] ?? null;
    if ($next && strpos($next,'client_id')===false)
      $next .= "&client_id={$c}";
    $pages++;
  }

  // Fallback — some accounts expose albums only via /playlists
  if (empty($out)) {
    $next = "https://api-v2.soundcloud.com/users/{$USER_ID}/playlists?limit=50&client_id={$c}";
    $pages = 0;
    while ($next && $pages < 5) {
      $body = hget($next);
      if (!$body) break;
      $data = json_decode($body, true);
      if (!$data) break;
      foreach ($data['collection'] ?? [] as $p) {
        $isAlbum = ($p['is_album'] ?? false) || (($p['set_type'] ?? '') === 'album');
        if ($isAlbum) $out[] = $p;
      }
      $next = $data['next_href'] ?? null;
      if ($next && strpos($next,'client_id')===false)
        $next .= "&client_id={$c}";
      $pages++;
    }
  }
  return $out;
}

/* Resolve a fresh, directly-playable stream URL for one track id.
   Returns the URL string, or null on failure. */
function resolve_stream($id, $c) {
  // Method 1: /streams endpoint (progressive MP3)
  $body = hget("https://api-v2.soundcloud.com/tracks/{$id}/streams?client_id={$c}");
  $data = $body ? json_decode($body, true) : null;
  if ($data && !empty($data['http_mp3_128_url'])) {
    return $data['http_mp3_128_url'];
  }

  // Method 2: track media transcodings
  $body = hget("https://api-v2.soundcloud.com/tracks/{$id}?client_id={$c}");
  $track = $body ? json_decode($body, true) : null;
  if ($track) {
    $tcs = $track['media']['transcodings'] ?? [];
    // Prefer progressive MP3
    foreach ($tcs as $tc) {
      if (($tc['format']['protocol'] ?? '') === 'progressive') {
        $url = ($tc['url'] ?? '') . '?client_id=' . $c;
        $sb = hget($url);
        $sd = $sb ? json_decode($sb, true) : null;
        if ($sd && !empty($sd['url'])) return $sd['url'];
      }
    }
    // Fallback: HLS
    foreach ($tcs as $tc) {
      if (($tc['format']['protocol'] ?? '') === 'hls') {
        $url = ($tc['url'] ?? '') . '?client_id=' . $c;
        $sb = hget($url);
        $sd = $sb ? json_decode($sb, true) : null;
        if ($sd && !empty($sd['url'])) return $sd['url'];
      }
    }
  }
  return null;
}

/* The /users/{id}/tracks LIST endpoint does NOT include each track's wide
   "visual" image. The /tracks?ids=... batch endpoint does. So fetch visuals
   in batches of 50 (about 2 calls for ~78 tracks) and cache them server-side,
   refreshing every few hours. Returns a map of track_id => visual_url|null. */
function fetch_visuals($ids, &$c) {
  global $VCACHE, $VCACHE_TTL, $CACHE;

  $map = [];
  if (is_file($VCACHE) && (time()-filemtime($VCACHE) < $VCACHE_TTL)) {
    $j = json_decode(@file_get_contents($VCACHE), true);
    if (is_array($j)) $map = $j;
  }

  $missing = [];
  foreach ($ids as $id) {
    if (!array_key_exists((string)$id, $map)) $missing[] = (string)$id;
  }

  if (!empty($missing)) {
    $changed = false;
    foreach (array_chunk($missing, 50) as $chunk) {
      $u = "https://api-v2.soundcloud.com/tracks?ids=" . implode(',', $chunk) . "&client_id={$c}";
      $body = hget($u);
      $data = $body ? json_decode($body, true) : null;
      if (!is_array($data) || isset($data['error'])) {
        // refresh client_id once and retry this chunk
        if (is_file($CACHE)) unlink($CACHE);
        $c = cid();
        $u = "https://api-v2.soundcloud.com/tracks?ids=" . implode(',', $chunk) . "&client_id={$c}";
        $body = hget($u);
        $data = $body ? json_decode($body, true) : null;
      }
      if (!is_array($data)) continue;
      foreach ($data as $t) {
        if (!isset($t['id'])) continue;
        $map[(string)$t['id']] = $t['visuals']['visuals'][0]['visual_url'] ?? null;
        $changed = true;
      }
    }
    if ($changed) @file_put_contents($VCACHE, json_encode($map));
  }
  return $map;
}

$action = $_GET['action'] ?? 'tracks';
$c = cid();

// ── TRACKS ──────────────────────────────────────────────
if ($action === 'tracks') {
  $all = fetch_all_tracks($c);

  // Enrich each track with its wide "visual" banner (cached, batched).
  $ids = [];
  foreach ($all as $t) $ids[] = (string)$t['id'];
  $vis = fetch_visuals($ids, $c);
  foreach ($all as &$t) {
    if (empty($t['banner']) && !empty($vis[$t['id']])) $t['banner'] = $vis[$t['id']];
  }
  unset($t);

  echo json_encode(['ok'=>true,'tracks'=>$all,'count'=>count($all)]);
  exit;
}

// ── ALBUMS ──────────────────────────────────────────────
// Returns each album with its FULL nested track objects (same shape as ?action=tracks),
// so the app can play an album directly with no extra calls.
if ($action === 'albums') {
  // 1) All of the user's tracks -> id => full track map (avoids SoundCloud's partial-track issue)
  $tracks = fetch_all_tracks($c);
  $byId = [];
  foreach ($tracks as $t) $byId[$t['id']] = $t;

  // 2) The user's albums
  $albumsRaw = fetch_albums($c);

  // 3) Build album objects with full, ordered tracks
  $albums = [];
  foreach ($albumsRaw as $a) {
    // Inline map from the album's own (partly-full) track objects, as a backup source
    $inline = [];
    foreach ($a['tracks'] ?? [] as $tr) {
      if (isset($tr['id']) && isset($tr['title'])) {
        $inline[(string)$tr['id']] = build_track($tr);
      }
    }

    // Ordered list of track ids for this album
    $ids = [];
    foreach ($a['tracks'] ?? [] as $tr) {
      if (isset($tr['id'])) $ids[] = (string)$tr['id'];
    }
    // Safety: if the album carried no inline tracks, fetch its detail once
    if (empty($ids) && isset($a['id'])) {
      $pb = hget("https://api-v2.soundcloud.com/playlists/{$a['id']}?client_id={$c}");
      $pd = $pb ? json_decode($pb, true) : null;
      foreach ($pd['tracks'] ?? [] as $tr) {
        if (isset($tr['id'])) $ids[] = (string)$tr['id'];
        if (isset($tr['id']) && isset($tr['title']))
          $inline[(string)$tr['id']] = build_track($tr);
      }
    }

    // Map ids -> full track objects (prefer the global map, then inline)
    $full = [];
    foreach ($ids as $tid) {
      if (isset($byId[$tid]))        $full[] = $byId[$tid];
      elseif (isset($inline[$tid]))  $full[] = $inline[$tid];
    }

    // Album cover: hi-res, or borrow the first track's artwork
    $art = $a['artwork_url'] ?? null;
    if ($art) $art = str_replace('-large','-t500x500',$art);
    if (!$art && !empty($full) && !empty($full[0]['artwork']))
      $art = str_replace('-t300x300','-t500x500',$full[0]['artwork']);

    $albums[] = [
      'id'          => (string)($a['id'] ?? ''),
      'title'       => $a['title'] ?? 'Album',
      'artwork'     => $art,
      'track_count' => count($full) ?: (int)($a['track_count'] ?? 0),
      'tracks'      => $full,
    ];
  }

  echo json_encode(['ok'=>true,'albums'=>$albums,'count'=>count($albums)]);
  exit;
}

// ── PLAY ────────────────────────────────────────────────
// Resolves a FRESH SoundCloud URL on every request and 302-redirects to it.
// The app points each track's audio source at this URL, so streams never go stale.
if ($action === 'play') {
  $id = preg_replace('/[^0-9]/','', $_GET['id'] ?? '');
  if (!$id) { http_response_code(400); header('Content-Type: text/plain'); echo 'No ID'; exit; }

  $url = resolve_stream($id, $c);
  if (!$url) {
    // Refresh client_id once and retry
    if (is_file($CACHE)) unlink($CACHE);
    $c = cid();
    $url = resolve_stream($id, $c);
  }

  if ($url) {
    header('Location: ' . $url, true, 302);
    exit;
  }
  http_response_code(404);
  header('Content-Type: text/plain');
  echo 'Stream not found';
  exit;
}

// ── STREAM (legacy JSON; kept for compatibility) ────────
if ($action === 'stream') {
  $id = preg_replace('/[^0-9]/','', $_GET['id'] ?? '');
  if (!$id) { echo json_encode(['ok'=>false,'error'=>'No ID']); exit; }

  $url = resolve_stream($id, $c);
  if (!$url) {
    if (is_file($CACHE)) unlink($CACHE);
    $c = cid();
    $url = resolve_stream($id, $c);
  }
  if ($url) { echo json_encode(['ok'=>true,'url'=>$url]); exit; }

  echo json_encode(['ok'=>false,'error'=>'No stream found','cid_used'=>substr($c,0,8).'...']);
  exit;
}

echo json_encode(['ok'=>false,'error'=>'Unknown action']);
