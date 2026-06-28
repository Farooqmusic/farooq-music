import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:just_audio_background/just_audio_background.dart';

const kBaseUrl = 'https://farooqmusic.com/mobile.php';
const kBg      = Color(0xFF1a0e22);
const kCard    = Color(0xFF23172b);
const kPrimary = Color(0xFF9d4edd);
const kLight   = Color(0xFFc77dff);
const kOn      = Color(0xFFefe7f5);
const kMuted   = Color(0xFFb39fc4);
const kBorder  = Color(0x33c77dff);

class SCTrack {
  final String id, title;
  final String? genre, artworkUrl, lyrics, explanation;
  final int? duration, plays;
  const SCTrack({required this.id, required this.title,
    this.genre, this.artworkUrl, this.duration, this.plays,
    this.lyrics, this.explanation});
  factory SCTrack.fromJson(Map<String, dynamic> j) {
    final art = (j['artwork'] ?? j['artwork_url']) as String?;
    String? str(dynamic v) => (v == null || v == '') ? null : v.toString();
    return SCTrack(
      id: j['id'].toString(), title: j['title'] ?? 'Unknown',
      genre: (j['genre'] ?? '') == '' ? null : j['genre'] as String,
      artworkUrl: art,
      duration: j['duration'] is int ? j['duration'] as int : null,
      plays: j['plays'] is int ? j['plays'] as int : null,
      lyrics: str(j['lyrics']),
      explanation: str(j['explanation']));
  }
}

Future<List<SCTrack>> fetchTracks() async {
  final r = await http.get(Uri.parse('$kBaseUrl?action=tracks'));
  if (r.statusCode == 200) {
    final d = json.decode(r.body);
    if (d['ok'] == true)
      return (d['tracks'] as List).map((t) => SCTrack.fromJson(t)).toList();
    throw Exception(d['error'] ?? 'API error');
  }
  throw Exception('HTTP ${r.statusCode}');
}

class Album {
  final String id, title;
  final String? artworkUrl;
  final int trackCount;
  final List<SCTrack> tracks;
  const Album({required this.id, required this.title, this.artworkUrl,
    required this.trackCount, required this.tracks});
  factory Album.fromJson(Map<String, dynamic> j) {
    final ts = ((j['tracks'] as List?) ?? [])
      .map((t) => SCTrack.fromJson(t as Map<String, dynamic>)).toList();
    return Album(
      id: j['id'].toString(),
      title: j['title'] ?? 'Album',
      artworkUrl: (j['artwork'] ?? '') == '' ? null : j['artwork'] as String,
      trackCount: j['track_count'] is int ? j['track_count'] as int : ts.length,
      tracks: ts);
  }
}

Future<List<Album>> fetchAlbums() async {
  final r = await http.get(Uri.parse('$kBaseUrl?action=albums'));
  if (r.statusCode == 200) {
    final d = json.decode(r.body);
    if (d['ok'] == true)
      return (d['albums'] as List).map((a) => Album.fromJson(a)).toList();
    throw Exception(d['error'] ?? 'API error');
  }
  throw Exception('HTTP ${r.statusCode}');
}

final player       = AudioPlayer();
final currentTrack = ValueNotifier<SCTrack?>(null);
final isPlaying    = ValueNotifier<bool>(false);
final isShuffle    = ValueNotifier<bool>(false);
final isRepeat     = ValueNotifier<bool>(false);   // true = repeat current track
final isPreparing  = ValueNotifier<bool>(false);   // resolving playlist URLs

List<SCTrack> queue = [];                 // same order as the loaded playlist
ConcatenatingAudioSource? _playlist;
String _loadedSig = '';                   // ids of the currently loaded list
int _playToken = 0;

String _sigOf(List<SCTrack> ts) => ts.map((t) => t.id).join(',');

// Each track's source points at mobile.php?action=play&id=X. That endpoint
// 302-redirects to a FRESH SoundCloud URL on every request, so the player always
// gets a valid (non-expired) stream — both for the first track and for each
// auto-advance. No URLs are resolved up front, so playback starts instantly.
AudioSource _sourceFor(SCTrack t) => AudioSource.uri(
  Uri.parse('$kBaseUrl?action=play&id=${t.id}'),
  tag: MediaItem(
    id: t.id,
    title: t.title,
    artist: 'Mohammad Farooq \u00b7 Farooq Music',
    artUri: t.artworkUrl != null ? Uri.tryParse(t.artworkUrl!) : null,
  ),
);

Future<void> playQueue(List<SCTrack> tracks, int index) async {
  if (tracks.isEmpty) return;
  final token = ++_playToken;
  final sig = _sigOf(tracks);

  // Same list already loaded -> just jump to the tapped track (instant).
  if (sig == _loadedSig && _playlist != null && queue.isNotEmpty) {
    final at = queue.indexWhere((t) => t.id == tracks[index].id);
    await player.seek(Duration.zero, index: at < 0 ? 0 : at);
    await player.play();
    return;
  }

  isPreparing.value = true;
  currentTrack.value = tracks[index];        // show tapped track right away
  try {
    // Build all sources directly from the proxy URLs — no up-front resolving.
    final sources = tracks.map(_sourceFor).toList();
    queue = [...tracks];
    _playlist = ConcatenatingAudioSource(children: sources);
    _loadedSig = sig;

    await player.setLoopMode(isRepeat.value ? LoopMode.one : LoopMode.all);
    await player.setShuffleModeEnabled(isShuffle.value);
    await player.setAudioSource(_playlist!, initialIndex: index);
    if (token != _playToken) return;
    if (isShuffle.value) await player.shuffle();
    await player.play();
  } catch (e) {
    debugPrint('playQueue error: $e');
  } finally {
    if (token == _playToken) isPreparing.value = false;
  }
}

void nextTrack() => player.seekToNext();
void prevTrack() => player.seekToPrevious();
void togglePlay() => player.playing ? player.pause() : player.play();

Future<void> toggleShuffle() async {
  isShuffle.value = !isShuffle.value;
  await player.setShuffleModeEnabled(isShuffle.value);
  if (isShuffle.value) await player.shuffle();
}

Future<void> toggleRepeat() async {
  isRepeat.value = !isRepeat.value;
  await player.setLoopMode(isRepeat.value ? LoopMode.one : LoopMode.all);
}

// Safety net: if a track errors mid-playback (rare — e.g. a CDN token expired
// during a very long pause), rebuild its source so the player re-requests a fresh
// redirect from mobile.php?action=play, then resume from the start of that track.
Future<void> _recoverIndex(int i) async {
  if (_playlist == null || i < 0 || i >= queue.length) return;
  try {
    await _playlist!.removeAt(i);
    await _playlist!.insert(i, _sourceFor(queue[i]));
    await player.seek(Duration.zero, index: i);
    await player.play();
  } catch (_) {
    player.seekToNext();
  }
}

void shareTrack(SCTrack track) {
  final url = 'https://farooqmusic.com/share.php?track=${track.id}';
  Share.share('${track.title} — Farooq Music\n$url');
}

Future<void> openUrl(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

String fmtPlays(int? n) {
  if (n == null) return '';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K plays';
  return '$n plays';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.farooqmusic.app.channel.audio',
    androidNotificationChannelName: 'Farooq Music',
    androidNotificationOngoing: true,
  );
  // Configure audio session — keeps audio playing in background
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  session.interruptionEventStream.listen((event) {
    if (event.begin) { player.pause(); }
    else { if (event.type == AudioInterruptionType.pause) player.play(); }
  });
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: kBg));
  player.playerStateStream.listen((s) {
    isPlaying.value = s.playing;
  });
  // Keep the UI in sync with whichever track the sequence is on
  // (covers in-app next/prev AND the lock-screen buttons).
  player.currentIndexStream.listen((i) {
    if (i != null && i >= 0 && i < queue.length) currentTrack.value = queue[i];
  });
  // If a SoundCloud URL has expired by the time we reach it, re-fetch it.
  player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace st) {
    final i = player.currentIndex;
    debugPrint('playback error: $e');
    if (i != null) _recoverIndex(i);
  });
  runApp(const FarooqApp());
}

class FarooqApp extends StatelessWidget {
  const FarooqApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Farooq Music', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: kBg,
      colorScheme: const ColorScheme.dark(
        primary: kPrimary, secondary: kLight, surface: kCard)),
    home: const HomeScreen());
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeState();
}
class _HomeState extends State<HomeScreen> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: _tab,
      children: const [MusicTab(), VideoTab(), AboutTab()]),
    bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
      const MiniPlayer(),
      NavigationBar(backgroundColor: kCard, selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        indicatorColor: kPrimary.withOpacity(0.25),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.music_note_outlined, color: kMuted),
            selectedIcon: Icon(Icons.music_note, color: kLight),
            label: 'Music'),
          NavigationDestination(
            icon: Icon(Icons.smart_display_outlined, color: kMuted),
            selectedIcon: Icon(Icons.smart_display, color: kLight),
            label: 'Videos'),
          NavigationDestination(
            icon: Icon(Icons.person_outline, color: kMuted),
            selectedIcon: Icon(Icons.person, color: kLight),
            label: 'About')])]));
}

class MusicTab extends StatefulWidget {
  const MusicTab({super.key});
  @override State<MusicTab> createState() => _MusicState();
}
class _MusicState extends State<MusicTab> {
  List<SCTrack> _all = [];
  List<Album> _albums = [];
  String _q = '';
  int _sort = 0;                 // 0 newest, 1 oldest, 2 A-Z, 3 most played, 4 shuffle
  List<SCTrack>? _shuffled;      // stable random order for the Shuffle sort
  bool _loading = true;
  String? _error;

  static const _sortLabels =
    ['Newest', 'Oldest', 'A–Z', 'Most played', 'Shuffle'];

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final t = await fetchTracks();
      setState(() { _all = t; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
      return;
    }
    // Albums are best-effort: a failure here must not break the music list.
    try {
      final a = await fetchAlbums();
      if (mounted) setState(() { _albums = a; });
    } catch (_) {}
  }

  List<SCTrack> get _featured => _all.take(10).toList();

  List<SCTrack> get _mostPlayed {
    final l = [..._all]..sort((a, b) => (b.plays ?? 0).compareTo(a.plays ?? 0));
    return l.take(10).toList();
  }

  List<SCTrack> get _sorted {
    final l = [..._all];
    switch (_sort) {
      case 1: return l.reversed.toList();
      case 2: l.sort((a, b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase())); return l;
      case 3: l.sort((a, b) => (b.plays ?? 0).compareTo(a.plays ?? 0)); return l;
      case 4: return _shuffled ?? l;     // stable random order
      default: return l;                 // newest (API order)
    }
  }

  List<SCTrack> get _visible {
    final base = _sorted;
    if (_q.isEmpty) return base;
    final q = _q.toLowerCase();
    return base.where((t) =>
      t.title.toLowerCase().contains(q) ||
      (t.genre ?? '').toLowerCase().contains(q)).toList();
  }

  Future<void> _playAll({bool shuffle = false}) async {
    final list = _sorted;
    if (list.isEmpty) return;
    isShuffle.value = shuffle;
    await playQueue(list, 0);
  }

  String _plays(int? n) {
    if (n == null) return '';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K plays';
    return '$n plays';
  }

  Widget _artPh() => Container(color: kCard,
    child: const Icon(Icons.music_note, color: kPrimary, size: 40));

  Widget _art(SCTrack t) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(width: 150, height: 150,
      child: t.artworkUrl != null
        ? Image.network(t.artworkUrl!, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _artPh())
        : _artPh()));

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: kBg,
    body: SafeArea(child: Column(children: [
      // ---- Header ----
      Container(padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
        decoration: const BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF2d1b3d), kBg])),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Farooq Music', style: TextStyle(
            color: kLight, fontSize: 26, fontWeight: FontWeight.w900)),
          const Text('Mohammad Farooq · AI Music',
            style: TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 12),
          Container(decoration: BoxDecoration(color: kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder)),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: const TextStyle(color: kOn),
              decoration: const InputDecoration(
                hintText: 'Search tracks...',
                hintStyle: TextStyle(color: kMuted),
                prefixIcon: Icon(Icons.search, color: kMuted),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 12)))),
        ])),
      // ---- Body ----
      Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator(color: kPrimary))
        : _error != null
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center,
              children: [
              const Icon(Icons.wifi_off, color: kMuted, size: 48),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: kMuted, fontSize: 12),
                textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load,
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                child: const Text('Try again'))]))
          : _q.isNotEmpty ? _searchResults() : _home())])));

  // ---------- Search results ----------
  Widget _searchResults() {
    final r = _visible;
    if (r.isEmpty) {
      return const Center(child: Text('No tracks found',
        style: TextStyle(color: kMuted)));
    }
    return ListView.builder(padding: const EdgeInsets.only(top: 6, bottom: 8),
      itemCount: r.length,
      itemBuilder: (_, i) => TrackTile(track: r[i],
        onTap: () => playQueue(r, i)));
  }

  // ---------- Home ----------
  Widget _home() {
    final feat = _featured;
    final pop  = _mostPlayed;
    final all  = _sorted;
    return CustomScrollView(slivers: [
      // Play all / Shuffle
      SliverToBoxAdapter(child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
        child: Row(children: [
          Expanded(child: ElevatedButton.icon(
            onPressed: () => _playAll(shuffle: false),
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12))),
            icon: const Icon(Icons.play_arrow, color: Colors.white),
            label: const Text('Play all', style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700)))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(
            onPressed: () => _playAll(shuffle: true),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: kPrimary),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12))),
            icon: const Icon(Icons.shuffle, color: kLight),
            label: const Text('Shuffle', style: TextStyle(
              color: kLight, fontWeight: FontWeight.w700)))),
        ]))),
      _sectionHeader('New Releases'),
      SliverToBoxAdapter(child: _cardRow(feat, showPlays: false)),
      if (_albums.isNotEmpty) ...[
        _sectionHeader('Albums'),
        SliverToBoxAdapter(child: _albumRow(_albums)),
      ],
      _sectionHeader('Most Played'),
      SliverToBoxAdapter(child: _cardRow(pop, showPlays: true, ranked: true)),
      // All Tracks header + sort
      SliverToBoxAdapter(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
        child: Row(children: [
          const Expanded(child: Text('All Tracks', style: TextStyle(
            color: kOn, fontSize: 17, fontWeight: FontWeight.w800))),
          PopupMenuButton<int>(
            color: kCard,
            initialValue: _sort,
            onSelected: (v) => setState(() {
              _sort = v;
              if (v == 4) _shuffled = [..._all]..shuffle();
            }),
            itemBuilder: (_) => [
              for (var i = 0; i < _sortLabels.length; i++)
                PopupMenuItem(value: i, child: Text(_sortLabels[i],
                  style: const TextStyle(color: kOn)))],
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_sortLabels[_sort], style: const TextStyle(
                color: kLight, fontSize: 13)),
              const Icon(Icons.arrow_drop_down, color: kLight)])),
        ]))),
      SliverList(delegate: SliverChildBuilderDelegate(
        (_, i) => TrackTile(track: all[i], onTap: () => playQueue(all, i)),
        childCount: all.length)),
      const SliverToBoxAdapter(child: SizedBox(height: 10)),
    ]);
  }

  Widget _sectionHeader(String t) => SliverToBoxAdapter(child: Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: Text(t, style: const TextStyle(
      color: kOn, fontSize: 17, fontWeight: FontWeight.w800))));

  Widget _albumArt(Album a) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(width: 150, height: 150,
      child: a.artworkUrl != null
        ? Image.network(a.artworkUrl!, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _artPh())
        : _artPh()));

  Widget _albumRow(List<Album> list) => SizedBox(
    height: 200,
    child: ListView.builder(scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final a = list[i];
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AlbumScreen(album: a))),
          child: Container(width: 150,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              _albumArt(a),
              const SizedBox(height: 6),
              Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kOn, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
              Text('${a.trackCount} tracks', style: const TextStyle(
                color: kMuted, fontSize: 11)),
            ])));
      }));

  Widget _cardRow(List<SCTrack> list,
      {bool showPlays = false, bool ranked = false}) => SizedBox(
    height: showPlays ? 212 : 196,
    child: ListView.builder(scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final t = list[i];
        return GestureDetector(
          onTap: () => playQueue(list, i),
          child: Container(width: 150,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              ranked
                ? Stack(children: [
                    _art(t),
                    Positioned(left: 8, top: 8, child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: Colors.black54,
                        borderRadius: BorderRadius.circular(99)),
                      child: Text('#${i + 1}', style: const TextStyle(
                        color: kLight, fontSize: 12,
                        fontWeight: FontWeight.w800)))),
                  ])
                : _art(t),
              const SizedBox(height: 6),
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kOn, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
              if (showPlays)
                Text(_plays(t.plays), style: const TextStyle(
                  color: kMuted, fontSize: 11)),
            ])));
      }));
}

class TrackTile extends StatelessWidget {
  final SCTrack track; final VoidCallback onTap;
  const TrackTile({super.key, required this.track, required this.onTap});
  String _fmt(int? ms) { if (ms==null) return '';
    final d = Duration(milliseconds: ms);
    return '${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}'; }
  @override
  Widget build(BuildContext context) => InkWell(onTap: onTap,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal:14, vertical:4),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder)),
      child: Row(children: [
        ClipRRect(borderRadius: BorderRadius.circular(8),
          child: track.artworkUrl != null
            ? Image.network(track.artworkUrl!, width:52, height:52,
                fit: BoxFit.cover,
                errorBuilder: (_,__,___) => _ph())
            : _ph()),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(track.title, style: const TextStyle(color: kOn,
            fontWeight: FontWeight.w600, fontSize: 14),
            maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Row(children: [
            if (track.genre != null) ...[
              Container(padding: const EdgeInsets.symmetric(
                horizontal:7, vertical:2),
                decoration: BoxDecoration(
                  color: kPrimary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(99)),
                child: Text(track.genre!,
                  style: const TextStyle(color:kLight, fontSize:10))),
              const SizedBox(width: 6)],
            Text(_fmt(track.duration),
              style: const TextStyle(color:kMuted, fontSize:11))])])),
        IconButton(
          icon: const Icon(Icons.share, color: kMuted, size: 20),
          onPressed: () => shareTrack(track)),
        const Icon(Icons.play_circle, color:kPrimary, size:32)])));
  Widget _ph() => Container(width:52, height:52, color:kBg,
    child: const Icon(Icons.music_note, color:kPrimary));
}

class AlbumScreen extends StatelessWidget {
  final Album album;
  const AlbumScreen({super.key, required this.album});

  // Upgrade SoundCloud artwork to a crisp t500x500 where possible.
  String _hiRes(String url) => url.replaceAll('-t300x300.', '-t500x500.');

  Future<void> _play({bool shuffle = false}) async {
    if (album.tracks.isEmpty) return;
    isShuffle.value = shuffle;
    await playQueue(album.tracks, 0);
  }

  Widget _cover(double side) {
    final url = album.artworkUrl;
    Widget ph() => Container(color: kCard,
      child: Icon(Icons.album, color: kPrimary, size: side * 0.3));
    return Container(width: side, height: side,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.35),
          blurRadius: 34, spreadRadius: 3)]),
      child: ClipRRect(borderRadius: BorderRadius.circular(18),
        child: url == null ? ph()
          : Image.network(_hiRes(url), width: side, height: side,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Image.network(url,
                width: side, height: side, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ph()))));
  }

  @override
  Widget build(BuildContext context) {
    final side = (MediaQuery.of(context).size.width - 120)
      .clamp(180.0, 260.0).toDouble();
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0,
        iconTheme: const IconThemeData(color: kOn),
        title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: kOn, fontSize: 16,
            fontWeight: FontWeight.w700))),
      bottomNavigationBar: const MiniPlayer(),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
          child: Column(children: [
            Center(child: _cover(side)),
            const SizedBox(height: 18),
            Text(album.title, textAlign: TextAlign.center,
              style: const TextStyle(color: kOn, fontSize: 20,
                fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('Album · ${album.tracks.length} tracks',
              style: const TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: ElevatedButton.icon(
                onPressed: () => _play(shuffle: false),
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.play_arrow, color: Colors.white),
                label: const Text('Play all', style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)))),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(
                onPressed: () => _play(shuffle: true),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kPrimary),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.shuffle, color: kLight),
                label: const Text('Shuffle', style: TextStyle(
                  color: kLight, fontWeight: FontWeight.w700)))),
            ]),
            const SizedBox(height: 8),
          ]))),
        SliverList(delegate: SliverChildBuilderDelegate(
          (_, i) => TrackTile(track: album.tracks[i],
            onTap: () => playQueue(album.tracks, i)),
          childCount: album.tracks.length)),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
      ]));
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SCTrack?>(
    valueListenable: currentTrack,
    builder: (_, track, __) {
      if (track == null) return const SizedBox.shrink();
      return GestureDetector(
        onTap: () => showModalBottomSheet(context: context,
          isScrollControlled: true, backgroundColor: Colors.transparent,
          builder: (_) => const FullPlayer()),
        child: Container(height: 68,
          decoration: BoxDecoration(color: kCard,
            border: Border(top: BorderSide(color: kBorder)),
            boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.15),
              blurRadius: 20, offset: const Offset(0,-4))]),
          child: Row(children: [
            const SizedBox(width: 12),
            if (track.artworkUrl != null)
              ClipRRect(borderRadius: BorderRadius.circular(6),
                child: Image.network(track.artworkUrl!,
                  width:44, height:44, fit:BoxFit.cover)),
            const SizedBox(width: 12),
            Expanded(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track.title, style: const TextStyle(color:kOn,
                fontWeight:FontWeight.w600, fontSize:13),
                maxLines:1, overflow:TextOverflow.ellipsis),
              const Text('Farooq Music',
                style: TextStyle(color:kMuted, fontSize:11))])),
            ValueListenableBuilder<bool>(
              valueListenable: isPlaying,
              builder: (_, p, __) => Row(children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous, color:kOn, size:22),
                  onPressed: prevTrack),
                ValueListenableBuilder<bool>(
                  valueListenable: isPreparing,
                  builder: (_, prep, __) => prep
                    ? const Padding(padding: EdgeInsets.all(8),
                        child: SizedBox(width:24, height:24,
                          child: CircularProgressIndicator(
                            strokeWidth:2.4, color:kPrimary)))
                    : IconButton(
                        icon: Icon(p ? Icons.pause_circle : Icons.play_circle,
                          color:kPrimary, size:38),
                        onPressed: togglePlay)),
                IconButton(
                  icon: const Icon(Icons.skip_next, color:kOn, size:22),
                  onPressed: nextTrack)])),
            const SizedBox(width: 4)])));
    });
}

class FullPlayer extends StatelessWidget {
  const FullPlayer({super.key});
  String _fmt(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}';

  // Upgrade SoundCloud artwork from the small t300x300 to a crisp t500x500.
  String _hiRes(String url) => url.replaceAll('-t300x300.', '-t500x500.');

  Widget _cover(SCTrack? track, double side) {
    final url = track?.artworkUrl;
    Widget ph() => Container(color: kCard,
      child: Icon(Icons.music_note, color: kPrimary, size: side * 0.3));
    return Container(width: side, height: side,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.4),
          blurRadius: 40, spreadRadius: 4)]),
      child: ClipRRect(borderRadius: BorderRadius.circular(20),
        child: url == null ? ph()
          : Image.network(_hiRes(url), width: side, height: side,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Image.network(url,
                width: side, height: side, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ph()))));
  }
  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize:0.92, maxChildSize:0.95, minChildSize:0.5,
    builder: (_, ctrl) => Container(
      decoration: const BoxDecoration(color:kBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(children: [
        Container(margin: const EdgeInsets.only(top:12),
          width:40, height:4,
          decoration: BoxDecoration(color:kBorder,
            borderRadius: BorderRadius.circular(99))),
        const SizedBox(height: 20),
        ValueListenableBuilder<SCTrack?>(
          valueListenable: currentTrack,
          builder: (ctx, track, __) => Column(children: [
            _cover(track,
              (MediaQuery.of(ctx).size.width - 72).clamp(220.0, 340.0)
                .toDouble()),
            const SizedBox(height: 24),
            Padding(padding: const EdgeInsets.symmetric(horizontal:32),
              child: Text(track?.title ?? '',
                style: const TextStyle(color:kOn, fontSize:20,
                  fontWeight:FontWeight.w800),
                textAlign: TextAlign.center, maxLines:2,
                overflow: TextOverflow.ellipsis)),
            const SizedBox(height: 4),
            const Text('Mohammad Farooq · Farooq Music',
              style: TextStyle(color:kMuted, fontSize:13)),
            if (track != null && (track.genre != null || track.plays != null))
              Padding(padding: const EdgeInsets.only(top:6),
                child: Text([
                  if (track.genre != null) track.genre!.trim(),
                  if (track.plays != null) fmtPlays(track.plays),
                ].where((e) => e.isNotEmpty).join('   ·   '),
                  style: const TextStyle(color:kLight, fontSize:12))),
            const SizedBox(height: 8),
            Wrap(alignment: WrapAlignment.center,
              spacing: 2, runSpacing: 0, children: [
              if (track != null)
                TextButton.icon(
                  icon: const Icon(Icons.share, color:kLight, size:18),
                  label: const Text('Share',
                    style: TextStyle(color:kLight, fontSize:13)),
                  onPressed: () => shareTrack(track!)),
              if (track?.lyrics != null)
                TextButton.icon(
                  icon: const Icon(Icons.article_outlined,
                    color:kLight, size:18),
                  label: const Text('Lyrics',
                    style: TextStyle(color:kLight, fontSize:13)),
                  onPressed: () => openUrl(track!.lyrics!)),
              if (track?.explanation != null)
                TextButton.icon(
                  icon: const Icon(Icons.menu_book_outlined,
                    color:kLight, size:18),
                  label: const Text('Explanation',
                    style: TextStyle(color:kLight, fontSize:13)),
                  onPressed: () => openUrl(track!.explanation!))])])),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (_, ps) {
            final pos = ps.data ?? Duration.zero;
            final tot = player.duration ?? Duration.zero;
            final prog = tot.inMilliseconds > 0
              ? pos.inMilliseconds/tot.inMilliseconds : 0.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal:24),
              child: Column(children: [
                SliderTheme(data: SliderTheme.of(context).copyWith(
                  activeTrackColor:kPrimary, inactiveTrackColor:kBorder,
                  thumbColor:kLight, overlayColor:kPrimary.withOpacity(0.2),
                  trackHeight:4),
                  child: Slider(value: prog.clamp(0.0,1.0),
                    onChanged: (v) => player.seek(Duration(
                      milliseconds: (v*(player.duration
                        ?.inMilliseconds ?? 0)).round())))),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                  Text(_fmt(pos),
                    style: const TextStyle(color:kMuted, fontSize:12)),
                  Text(_fmt(tot),
                    style: const TextStyle(color:kMuted, fontSize:12))])]));
          }),
        const SizedBox(height: 20),
        ValueListenableBuilder<bool>(
          valueListenable: isPlaying,
          builder: (_, p, __) => Row(
            mainAxisAlignment: MainAxisAlignment.center, children: [
            ValueListenableBuilder<bool>(valueListenable: isShuffle,
              builder: (_, s, __) => IconButton(
                icon: Icon(Icons.shuffle,
                  color: s ? kLight : kMuted, size:26),
                onPressed: toggleShuffle)),
            IconButton(
              icon: const Icon(Icons.skip_previous, color:kOn, size:36),
              onPressed: prevTrack),
            Container(width:70, height:70,
              decoration: BoxDecoration(color:kPrimary,
                shape:BoxShape.circle,
                boxShadow: [BoxShadow(color:kPrimary.withOpacity(0.5),
                  blurRadius:20, spreadRadius:2)]),
              child: IconButton(
                icon: Icon(p ? Icons.pause : Icons.play_arrow,
                  color:Colors.white, size:36),
                onPressed: togglePlay)),
            IconButton(
              icon: const Icon(Icons.skip_next, color:kOn, size:36),
              onPressed: nextTrack),
            ValueListenableBuilder<bool>(valueListenable: isRepeat,
              builder: (_, r, __) => IconButton(
                icon: Icon(Icons.repeat,
                  color: r ? kLight : kMuted, size:26),
                onPressed: toggleRepeat))])),
        const SizedBox(height: 20)])));
}

class VideoTab extends StatelessWidget {
  const VideoTab({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: kBg,
    appBar: AppBar(backgroundColor: kBg,
      title: const Text('Videos',
        style: TextStyle(color:kOn, fontWeight:FontWeight.w800))),
    body: Center(child: Column(
      mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width:90, height:90,
        decoration: BoxDecoration(color:kCard, shape:BoxShape.circle,
          border: Border.all(color:kBorder, width:2)),
        child: const Icon(Icons.smart_display, color:kPrimary, size:44)),
      const SizedBox(height: 20),
      const Text('YouTube Videos',
        style: TextStyle(color:kOn, fontSize:22, fontWeight:FontWeight.w800)),
      const SizedBox(height: 6),
      const Text('@farooqmusicai',
        style: TextStyle(color:kLight, fontSize:14)),
      const SizedBox(height: 28),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor:kPrimary,
          padding: const EdgeInsets.symmetric(horizontal:24, vertical:12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(99))),
        icon: const Icon(Icons.open_in_new, color:Colors.white),
        label: const Text('Open YouTube Channel',
          style: TextStyle(color:Colors.white, fontWeight:FontWeight.w700)),
        onPressed: () => openUrl('https://www.youtube.com/@farooqmusicai')),
      const SizedBox(height: 10),
      const Text('In-app videos coming soon',
        style: TextStyle(color:kMuted, fontSize:12))])));
}

class _Link {
  final String name, url;
  const _Link(this.name, this.url);
}

const _listenLinks = <_Link>[
  _Link('SoundCloud', 'https://soundcloud.com/farooqmusic'),
  _Link('Spotify', 'https://open.spotify.com/artist/48uj0NCXikVLNlR9WItNIl'),
  _Link('Apple Music', 'https://music.apple.com/artist/1896118117'),
  _Link('YouTube Music',
    'https://music.youtube.com/channel/UC2PTlcCPO1ks-rz7LfCSIiw'),
  _Link('Amazon Music',
    'https://music.amazon.com/artists/B07VG49J2X/mohammad-farooq'),
  _Link('Tidal', 'https://tidal.com/artist/16247490'),
  _Link('Deezer', 'https://www.deezer.com/us/artist/69350722'),
  _Link('Anghami', 'https://play.anghami.com/artist/5113758'),
];

const _followLinks = <_Link>[
  _Link('YouTube', 'https://www.youtube.com/@farooqmusicai'),
  _Link('Instagram', 'https://www.instagram.com/farooqmusicai'),
  _Link('X', 'https://x.com/farooqmusicai'),
  _Link('TikTok', 'https://www.tiktok.com/@farooqmusicai'),
  _Link('Facebook', 'https://www.facebook.com/farooqmusicai'),
  _Link('Pinterest', 'https://www.pinterest.com/farooqmusic/'),
  _Link('Tumblr', 'https://www.tumblr.com/farooqmusic'),
];

const _steps = <List<String>>[
  ['01 · Words', 'Poetry first',
    'It starts with meaning — classical Urdu verse from poets like Jaun Elia '
    'and Hafeez Jalandhri, or original lyrics written to carry a feeling.'],
  ['02 · Sound', 'AI composition',
    'Using Suno AI, the words are shaped into music — blending styles from '
    'Turkish Anatolian rock to cinematic pop.'],
  ['03 · Craft', 'Shaped & refined',
    'Each track is guided, re-rolled and curated by Mohammad Farooq until the '
    'melody, mood and message sit exactly right.'],
  ['04 · Release', 'Out to the world',
    'The finished song goes live on SoundCloud and every major platform — and '
    'lands here for you to play first.'],
];

class AboutTab extends StatelessWidget {
  const AboutTab({super.key});

  Widget _chip(_Link l) => GestureDetector(
    onTap: () => openUrl(l.url),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(color: kCard,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: kBorder)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(l.name, style: const TextStyle(color: kOn, fontSize: 13,
          fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        const Icon(Icons.open_in_new, color: kLight, size: 14),
      ])));

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 22, 0, 10),
    child: Text(t, style: const TextStyle(color: kLight, fontSize: 13,
      fontWeight: FontWeight.w800, letterSpacing: 1.2)));

  Widget _bigButton(IconData icon, String label, VoidCallback onTap) =>
    GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder)),
      child: Row(children: [
        Icon(icon, color: kLight, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(color: kOn,
          fontSize: 14, fontWeight: FontWeight.w600))),
        const Icon(Icons.open_in_new, color: kMuted, size: 16),
      ])));

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: kBg,
    body: SafeArea(child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        // ---- Header ----
        Center(child: Column(children: [
          Container(width: 96, height: 96,
            decoration: BoxDecoration(shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.4),
                blurRadius: 30, spreadRadius: 2)]),
            child: ClipOval(child: Image.network(
              'https://farooqmusic.com/farooq-logo.png', fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: kCard,
                child: const Icon(Icons.music_note,
                  color: kPrimary, size: 40))))),
          const SizedBox(height: 14),
          const Text('Farooq Music', style: TextStyle(color: kOn,
            fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          const Text('Mohammad Farooq · AI Music Producer · Doha',
            textAlign: TextAlign.center,
            style: TextStyle(color: kMuted, fontSize: 12)),
        ])),
        // ---- Bio ----
        _sectionTitle('THE ARTIST'),
        const Text(
          'Farooq Music is Mohammad Farooq — a Doha-based digital AI music '
          'producer breathing new life into classical Urdu poetry. He blends '
          'the timeless verses of legends like Jaun Elia and Hafeez Jalandhri '
          'with global styles, from Turkish Anatolian rock to cinematic pop, '
          'creating modern, genre-defying Urdu tracks.',
          style: TextStyle(color: kOn, fontSize: 14, height: 1.55)),
        const SizedBox(height: 10),
        const Text(
          'New tracks land regularly, and everything you hear streams straight '
          'from SoundCloud. Follow along for each new release.',
          style: TextStyle(color: kMuted, fontSize: 13, height: 1.55)),
        // ---- How it's made ----
        _sectionTitle("HOW IT'S MADE"),
        ..._steps.map((s) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text(s[0], style: const TextStyle(color: kLight, fontSize: 11,
              fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            const SizedBox(height: 4),
            Text(s[1], style: const TextStyle(color: kOn, fontSize: 15,
              fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(s[2], style: const TextStyle(color: kMuted, fontSize: 12.5,
              height: 1.5)),
          ]))),
        // ---- Listen everywhere ----
        _sectionTitle('LISTEN EVERYWHERE'),
        Wrap(spacing: 8, runSpacing: 8,
          children: _listenLinks.map(_chip).toList()),
        // ---- Follow ----
        _sectionTitle('FOLLOW'),
        Wrap(spacing: 8, runSpacing: 8,
          children: _followLinks.map(_chip).toList()),
        // ---- Get in touch ----
        _sectionTitle('GET IN TOUCH'),
        _bigButton(Icons.email_outlined, 'contact@farooqmusic.com',
          () => openUrl('mailto:contact@farooqmusic.com')),
        const SizedBox(height: 10),
        _bigButton(Icons.chat_bubble_outline, 'WhatsApp Channel',
          () => openUrl(
            'https://whatsapp.com/channel/0029VbBsDpm2f3EL51meaF0x')),
        const SizedBox(height: 10),
        _bigButton(Icons.language, 'farooqmusic.com',
          () => openUrl('https://farooqmusic.com/')),
        const SizedBox(height: 24),
        Center(child: Text('Made with Suno AI · © Farooq Music',
          style: TextStyle(color: kMuted.withOpacity(0.7), fontSize: 11))),
      ])));
}