import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math';
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
  final String? genre, artworkUrl;
  final int? duration;
  const SCTrack({required this.id, required this.title,
    this.genre, this.artworkUrl, this.duration});
  factory SCTrack.fromJson(Map<String, dynamic> j) {
    final art = (j['artwork'] ?? j['artwork_url']) as String?;
    return SCTrack(
      id: j['id'].toString(), title: j['title'] ?? 'Unknown',
      genre: (j['genre'] ?? '') == '' ? null : j['genre'] as String,
      artworkUrl: art,
      duration: j['duration'] is int ? j['duration'] as int : null);
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

Future<String> getStreamUrl(String id) async {
  final r = await http.get(Uri.parse('$kBaseUrl?action=stream&id=$id'));
  if (r.statusCode == 200) {
    final d = json.decode(r.body);
    if (d['ok'] == true) return d['url'] as String;
    throw Exception(d['error'] ?? 'Stream error');
  }
  throw Exception('HTTP ${r.statusCode}');
}

final player       = AudioPlayer();
final currentTrack = ValueNotifier<SCTrack?>(null);
final isPlaying    = ValueNotifier<bool>(false);
final isShuffle    = ValueNotifier<bool>(false);
final isRepeat     = ValueNotifier<bool>(false);
List<SCTrack> queue = [];
int queueIndex = 0;

Future<void> playQueue(List<SCTrack> tracks, int index) async {
  queue = tracks; queueIndex = index; await _load();
}

int _loadToken = 0;
int _consecutiveErrors = 0;

Future<void> _load() async {
  if (queue.isEmpty) return;
  final myToken = ++_loadToken;            // newest tap wins; older loads abort
  final t = queue[queueIndex];
  currentTrack.value = t;
  try {
    final url = await getStreamUrl(t.id);
    if (myToken != _loadToken) return;
    if (url.isEmpty) throw Exception('empty stream url');
    await player.setAudioSource(AudioSource.uri(
      Uri.parse(url),
      tag: MediaItem(
        id: t.id,
        title: t.title,
        artist: 'Mohammad Farooq \u00b7 Farooq Music',
        artUri: t.artworkUrl != null ? Uri.tryParse(t.artworkUrl!) : null,
      ),
    ));
    if (myToken != _loadToken) return;
    _consecutiveErrors = 0;
    await player.play();
  } catch (e) {
    if (myToken != _loadToken) return;
    debugPrint('Load error: $e — skipping');
    _consecutiveErrors++;
    if (_consecutiveErrors < queue.length) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (myToken == _loadToken) nextTrack();
    } else {
      _consecutiveErrors = 0;                // give up after a full loop
    }
  }
}

void nextTrack() {
  if (queue.isEmpty) return;
  if (isShuffle.value) {
    if (queue.length > 1) {
      int n; do { n = Random().nextInt(queue.length); } while (n == queueIndex);
      queueIndex = n;
    }
  } else {
    queueIndex = (queueIndex + 1) % queue.length;
  }
  _load();
}

void prevTrack() {
  if (queue.isEmpty) return;
  queueIndex = (queueIndex - 1 + queue.length) % queue.length;
  _load();
}

void togglePlay() => player.playing ? player.pause() : player.play();

void shareTrack(SCTrack track) {
  final url = 'https://farooqmusic.com/share.php?track=${track.id}';
  Share.share('${track.title} — Farooq Music\n$url');
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
    if (s.processingState == ProcessingState.completed) {
      if (isRepeat.value) {
        player.seek(Duration.zero);
        player.play();
      } else {
        Future.delayed(const Duration(milliseconds: 300), nextTrack);
      }
    }
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
    body: IndexedStack(index: _tab, children: const [MusicTab(), VideoTab()]),
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
            label: 'Videos')])]));
}

class MusicTab extends StatefulWidget {
  const MusicTab({super.key});
  @override State<MusicTab> createState() => _MusicState();
}
class _MusicState extends State<MusicTab> {
  List<SCTrack> _all = [], _shown = [];
  bool _loading = true; String? _error;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final t = await fetchTracks();
      setState(() { _all = t; _shown = t; _loading = false; });
    } catch (e) { setState(() { _error = e.toString(); _loading = false; }); }
  }
  void _search(String q) => setState(() =>
    _shown = q.isEmpty ? _all : _all.where((t) =>
      t.title.toLowerCase().contains(q.toLowerCase()) ||
      (t.genre ?? '').toLowerCase().contains(q.toLowerCase())).toList());
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: kBg,
    body: SafeArea(child: Column(children: [
      Container(padding: const EdgeInsets.fromLTRB(18,18,18,10),
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
            child: TextField(onChanged: _search,
              style: const TextStyle(color: kOn),
              decoration: const InputDecoration(
                hintText: 'Search tracks...',
                hintStyle: TextStyle(color: kMuted),
                prefixIcon: Icon(Icons.search, color: kMuted),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 12)))),
          const SizedBox(height: 6),
          Text(_loading ? 'Loading...' : '${_shown.length} tracks',
            style: const TextStyle(color: kMuted, fontSize: 12))])),
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
          : ListView.builder(padding: const EdgeInsets.only(bottom: 8),
              itemCount: _shown.length,
              itemBuilder: (ctx, i) => TrackTile(
                track: _shown[i],
                onTap: () => playQueue(_shown, i))))])));
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
                IconButton(
                  icon: Icon(p ? Icons.pause_circle : Icons.play_circle,
                    color:kPrimary, size:38),
                  onPressed: togglePlay),
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
          builder: (_, track, __) => Column(children: [
            Container(width:240, height:240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color:kPrimary.withOpacity(0.4),
                  blurRadius:40, spreadRadius:4)]),
              child: ClipRRect(borderRadius: BorderRadius.circular(20),
                child: track?.artworkUrl != null
                  ? Image.network(track!.artworkUrl!, fit:BoxFit.cover)
                  : Container(color:kCard,
                      child: const Icon(Icons.music_note,
                        color:kPrimary, size:80)))),
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
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (track != null)
                TextButton.icon(
                  icon: const Icon(Icons.share, color:kLight, size:18),
                  label: const Text('Share',
                    style: TextStyle(color:kLight, fontSize:13)),
                  onPressed: () => shareTrack(track!))])])),
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
                onPressed: () => isShuffle.value = !isShuffle.value)),
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
                onPressed: () => isRepeat.value = !isRepeat.value))])),
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
        onPressed: () {}),
      const SizedBox(height: 10),
      const Text('In-app videos coming soon',
        style: TextStyle(color:kMuted, fontSize:12))])));
}