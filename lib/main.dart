import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:crypto/crypto.dart';
import 'package:image_picker/image_picker.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'dart:typed_data';
import 'dart:math';

const kBaseUrl = 'https://farooqmusic.com/mobile.php';
const kBg      = Color(0xFF1a0e22);
const kCard    = Color(0xFF23172b);
const kPrimary = Color(0xFF9d4edd);
const kLight   = Color(0xFFc77dff);
const kOn      = Color(0xFFefe7f5);
const kMuted   = Color(0xFFb39fc4);
const kBorder  = Color(0x33c77dff);

// ---- Auth / Supabase config ----
// The Supabase URL + publishable key are SAFE to ship inside the app — the
// publishable (anon) key is designed to live in client code. The same Supabase
// project is shared with Farooq Stars, so logging in here gives one account
// across both apps (for the future merged app).
const kSupabaseUrl       = 'https://yxrntgugocmhphkoibnp.supabase.co';
const kSupabaseKey       = 'sb_publishable_zyo6ulAr1J5BpX-7OEUHMg_RuAL1ONt';
// Google OAuth client IDs (public). iOS client = the app itself;
// web client = the "server" client Supabase verifies tokens against.
const kGoogleIosClientId =
  '557736899895-ad5169jo7cdmig54cd9nc7ova9fhuqg5.apps.googleusercontent.com';
const kGoogleWebClientId =
  '557736899895-oi900uac66s4j074p9nus93ovkgo860t.apps.googleusercontent.com';

// Handy Supabase client accessor (valid after Supabase.initialize in main()).
SupabaseClient get supabase => Supabase.instance.client;

// The currently logged-in user (null = guest). The whole UI listens to this.
final authUser = ValueNotifier<User?>(null);

// All loaded tracks, shared so the Search tab can read them without refetching.
final allTracks = ValueNotifier<List<SCTrack>>([]);

// Pretty display name for a user: metadata name -> email -> fallback.
String displayName(User u) {
  final n = u.userMetadata?['full_name'] ?? u.userMetadata?['name'];
  if (n is String && n.trim().isNotEmpty) return n.trim();
  return u.email ?? 'Farooq Music listener';
}

// ---------- Profile photo (avatar) ----------
// The current user's avatar URL (null = no photo). The UI listens to this so
// the picture updates instantly everywhere after a change.
final avatarUrl = ValueNotifier<String?>(null);
final _avatarPicker = ImagePicker();

// Load the saved avatar URL for the logged-in user from the `profiles` table.
Future<void> loadAvatarUrl() async {
  final user = supabase.auth.currentUser;
  if (user == null) { avatarUrl.value = null; return; }
  try {
    final row = await supabase
        .from('profiles').select('avatar_url').eq('id', user.id).maybeSingle();
    final url = row?['avatar_url'];
    avatarUrl.value = (url is String && url.isNotEmpty) ? url : null;
  } catch (_) {/* keep whatever we had */}
}

// Pick a photo, shrink + compress it, upload to Supabase Storage, and save the
// URL on the user's profile row. Returns true on success, false if cancelled.
Future<bool> pickAndUploadAvatar(ImageSource source) async {
  final user = supabase.auth.currentUser;
  if (user == null) throw 'Not signed in';
  final XFile? picked = await _avatarPicker.pickImage(
    source: source, maxWidth: 256, maxHeight: 256, imageQuality: 80);
  if (picked == null) return false; // user cancelled the picker
  final Uint8List bytes = await picked.readAsBytes();
  final path = '${user.id}/avatar.jpg';

  // 1) Upload the image to Storage.
  try {
    await supabase.storage.from('avatars').uploadBinary(
      path, bytes,
      fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'));
  } catch (e) {
    throw 'Upload step: $e';
  }

  final base = supabase.storage.from('avatars').getPublicUrl(path);
  // Same filename each time, so add a cache-buster to force the new image.
  final url = '$base?v=${DateTime.now().millisecondsSinceEpoch}';

  // 2) Save the URL on the user's profile row.
  try {
    await supabase.from('profiles').upsert({
      'id': user.id,
      'avatar_url': url,
      'updated_at': DateTime.now().toIso8601String(),
    });
  } catch (e) {
    throw 'Save step: $e';
  }

  avatarUrl.value = url;
  return true;
}

// Remove the current photo (storage object + profile field).
Future<void> removeAvatar() async {
  final user = supabase.auth.currentUser;
  if (user == null) return;
  try { await supabase.storage.from('avatars').remove(['${user.id}/avatar.jpg']); }
  catch (_) {}
  await supabase.from('profiles').upsert({
    'id': user.id,
    'avatar_url': null,
    'updated_at': DateTime.now().toIso8601String(),
  });
  avatarUrl.value = null;
}

class SCTrack {
  final String id, title;
  final String? genre, artworkUrl, bannerUrl, lyrics, explanation, waveformUrl;
  final int? duration, plays;
  const SCTrack({required this.id, required this.title,
    this.genre, this.artworkUrl, this.bannerUrl, this.duration, this.plays,
    this.lyrics, this.explanation, this.waveformUrl});
  factory SCTrack.fromJson(Map<String, dynamic> j) {
    final art = (j['artwork'] ?? j['artwork_url']) as String?;
    String? str(dynamic v) => (v == null || v == '') ? null : v.toString();
    return SCTrack(
      id: j['id'].toString(), title: j['title'] ?? 'Unknown',
      genre: (j['genre'] ?? '') == '' ? null : j['genre'] as String,
      artworkUrl: art,
      bannerUrl: str(j['banner']),
      waveformUrl: str(j['waveform']),
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
// Repeat mode: off (no loop), all (loop the whole current queue — used by the
// Home & Album "Repeat" buttons), one (loop the single current track — used by
// the now-playing player's "Repeat" button).
final repeatMode   = ValueNotifier<LoopMode>(LoopMode.off);
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

  // Same list already loaded -> just jump to the requested track (instant).
  // If shuffle is on, reshuffle first so "Play all" gives a fresh random order.
  if (sig == _loadedSig && _playlist != null && queue.isNotEmpty) {
    if (isShuffle.value) await player.shuffle();
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

    await player.setLoopMode(repeatMode.value);
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

// Repeat is a single global player mode. Tapping a "Repeat" button toggles
// between OFF and that button's mode. The Home/Album buttons use "all" (loop
// the queue); the player's button uses "one" (loop the single track).
Future<void> _setRepeat(LoopMode m) async {
  repeatMode.value = (repeatMode.value == m) ? LoopMode.off : m;
  await player.setLoopMode(repeatMode.value);
}
Future<void> toggleRepeatAll() => _setRepeat(LoopMode.all);
Future<void> toggleRepeatOne() => _setRepeat(LoopMode.one);

// A split pill: [ Shuffle | Repeat ] — both halves are toggles that highlight
// when active. Used on the Home page (scope = whole library) and the Album
// screen (scope = that album's tracks). "Play all" then plays respecting these
// toggles. Repeat here means "repeat all" (loop the queue).
class ShuffleRepeatPill extends StatelessWidget {
  const ShuffleRepeatPill({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: kPrimary),
        borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Expanded(child: ValueListenableBuilder<bool>(
          valueListenable: isShuffle,
          builder: (_, on, __) => _PillHalf(
            icon: Icons.shuffle, label: 'Shuffle',
            active: on, onTap: toggleShuffle))),
        Container(width: 1, color: kBorder),
        Expanded(child: ValueListenableBuilder<LoopMode>(
          valueListenable: repeatMode,
          builder: (_, m, __) => _PillHalf(
            icon: Icons.repeat, label: 'Repeat',
            active: m == LoopMode.all, onTap: toggleRepeatAll))),
      ]),
    );
  }
}

class _PillHalf extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _PillHalf({required this.icon, required this.label,
    required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = active ? Colors.white : kLight;
    return Material(
      color: active ? kPrimary : Colors.transparent,
      child: InkWell(onTap: onTap, child: Center(child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: c, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c,
            fontWeight: FontWeight.w700, fontSize: 13))),
      ]))),
    );
  }
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

// Universal smart share link. `s.php` shows a 1:1 thumbnail preview (OG image)
// in WhatsApp/iMessage etc., and on tap opens the song in the app if it's
// installed (iOS/Android) or falls back to the website. One link works
// everywhere — today it opens the web player; once the app is on the stores
// the same link opens the app automatically (no need to re-share).
void shareTrack(SCTrack track) {
  final url = 'https://farooqmusic.com/s.php?t=${track.id}';
  final msg = '🎵 ${track.title}\n'
      'Farooq Music — AI Urdu music by Mohammad Farooq 🎧\n\n'
      '$url';
  Share.share(msg, subject: '${track.title} — Farooq Music');
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

// ---------------------------------------------------------------------------
// Authentication helpers (Supabase + native Google / Apple)
// ---------------------------------------------------------------------------

// Native Google sign-in: get an ID token from Google, hand it to Supabase.
Future<void> signInWithGoogle() async {
  final google = GoogleSignIn.instance;
  // Opens the native Google account picker.
  final account = await google.authenticate();
  final idToken = account.authentication.idToken;
  if (idToken == null) {
    throw const AuthException('No Google ID token returned.');
  }
  // Access token is optional for Supabase; fetch it best-effort.
  String? accessToken;
  try {
    final authz =
      await account.authorizationClient.authorizationForScopes(const []);
    accessToken = authz?.accessToken;
  } catch (_) {}
  await supabase.auth.signInWithIdToken(
    provider: OAuthProvider.google,
    idToken: idToken,
    accessToken: accessToken,
  );
}

// Native Apple sign-in (iOS): nonce-protected ID token -> Supabase.
Future<void> signInWithApple() async {
  final rawNonce = supabase.auth.generateRawNonce();
  final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
  final credential = await SignInWithApple.getAppleIDCredential(
    scopes: const [
      AppleIDAuthorizationScopes.email,
      AppleIDAuthorizationScopes.fullName,
    ],
    nonce: hashedNonce,
  );
  final idToken = credential.identityToken;
  if (idToken == null) {
    throw const AuthException('No Apple ID token returned.');
  }
  await supabase.auth.signInWithIdToken(
    provider: OAuthProvider.apple,
    idToken: idToken,
    nonce: rawNonce,
  );
  // Apple only sends the name on the FIRST sign-in — persist it right away.
  final name = [credential.givenName, credential.familyName]
    .where((e) => e != null && e!.trim().isNotEmpty)
    .map((e) => e!.trim())
    .join(' ')
    .trim();
  if (name.isNotEmpty) {
    try {
      await supabase.auth.updateUser(UserAttributes(data: {'full_name': name}));
    } catch (_) {}
  }
}

Future<void> signOutUser() async {
  try { await GoogleSignIn.instance.signOut(); } catch (_) {}
  await supabase.auth.signOut();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---- Supabase (auth + shared backend with Farooq Stars) ----
  await Supabase.initialize(url: kSupabaseUrl, publishableKey: kSupabaseKey);
  authUser.value = supabase.auth.currentUser;
  loadAvatarUrl();
  supabase.auth.onAuthStateChange.listen((data) {
    authUser.value = data.session?.user;
    loadAvatarUrl();
  });

  // ---- Native Google sign-in (initialise once) ----
  try {
    await GoogleSignIn.instance.initialize(
      clientId: kGoogleIosClientId,
      serverClientId: kGoogleWebClientId,
    );
  } catch (_) {}

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
      children: const [MusicTab(), VideoTab(), PlaylistsTab(),
        SearchTab(), AboutTab()]),
    bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
      const MiniPlayer(),
      NavigationBar(backgroundColor: kCard, selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        indicatorColor: kPrimary.withOpacity(0.25),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined, color: kMuted),
            selectedIcon: Icon(Icons.home, color: kLight),
            label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.smart_display_outlined, color: kMuted),
            selectedIcon: Icon(Icons.smart_display, color: kLight),
            label: 'Videos'),
          NavigationDestination(
            icon: Icon(Icons.queue_music, color: kMuted),
            selectedIcon: Icon(Icons.queue_music, color: kLight),
            label: 'Playlists'),
          NavigationDestination(
            icon: Icon(Icons.search, color: kMuted),
            selectedIcon: Icon(Icons.search, color: kLight),
            label: 'Search'),
          NavigationDestination(
            icon: Icon(Icons.person_outline, color: kMuted),
            selectedIcon: Icon(Icons.person, color: kLight),
            label: 'About')])]));
}

// ---------------- Playlists tab (placeholder for Step 4) ----------------
class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: SafeArea(child: Center(child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: kCard, shape: BoxShape.circle,
            border: Border.all(color: kBorder)),
          child: const Icon(Icons.queue_music, color: kLight, size: 44)),
        const SizedBox(height: 18),
        const Text('Your Playlists', style: TextStyle(color: kOn,
          fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        const Text('Soon you\'ll be able to create your own playlists '
          'from any tracks. Coming next!',
          textAlign: TextAlign.center,
          style: TextStyle(color: kMuted, fontSize: 13, height: 1.5)),
      ])))));
}

// ---------------- Search tab ----------------
class SearchTab extends StatefulWidget {
  const SearchTab({super.key});
  @override State<SearchTab> createState() => _SearchState();
}
class _SearchState extends State<SearchTab> {
  String _q = '';
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: SafeArea(child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Container(
          decoration: BoxDecoration(color: kCard,
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
              contentPadding: EdgeInsets.symmetric(vertical: 14))))),
      Expanded(child: ValueListenableBuilder<List<SCTrack>>(
        valueListenable: allTracks,
        builder: (_, tracks, __) {
          final q = _q.trim().toLowerCase();
          if (q.isEmpty) {
            return const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Search your tracks by name or genre',
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 13))));
          }
          final r = tracks.where((t) =>
            t.title.toLowerCase().contains(q) ||
            (t.genre ?? '').toLowerCase().contains(q)).toList();
          if (r.isEmpty) {
            return const Center(child: Text('No tracks found',
              style: TextStyle(color: kMuted)));
          }
          return ListView.builder(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            itemCount: r.length,
            itemBuilder: (_, i) => TrackTile(track: r[i],
              onTap: () => playQueue(r, i)));
        })),
    ])));
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

  // Featured banner (daily-random, swipeable)
  final _bannerCtrl = PageController(viewportFraction: 0.92);
  int _bannerPage = 0;

  static const _sortLabels =
    ['Newest', 'Oldest', 'A–Z', 'Most played', 'Shuffle'];

  @override void initState() { super.initState(); _load(); }

  @override void dispose() { _bannerCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final t = await fetchTracks();
      allTracks.value = t;
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

  // A new random selection each day (stable within the day); only tracks
  // that have artwork, so the banner always looks good.
  List<SCTrack> get _bannerTracks {
    final withArt = _all.where((t) => t.artworkUrl != null).toList();
    if (withArt.isEmpty) return const [];
    final now = DateTime.now();
    final doy = now.difference(DateTime(now.year, 1, 1)).inDays;
    withArt.shuffle(Random(now.year * 1000 + doy));
    return withArt.take(8).toList();
  }

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

  Future<void> _playAll() async {
    final list = _sorted;
    if (list.isEmpty) return;
    // When shuffle is on, begin from a RANDOM track (not the newest one).
    final start = isShuffle.value ? Random().nextInt(list.length) : 0;
    await playQueue(list, start);
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
          Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Align(alignment: Alignment.centerLeft,
                child: Image.network(
                  'https://farooqmusic.com/farooq-music-logo.png',
                  height: 38, fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('Farooq Music',
                    style: TextStyle(color: kLight, fontSize: 26,
                      fontWeight: FontWeight.w900)))),
              const SizedBox(height: 3),
              const Text('AI Music',
                style: TextStyle(color: kMuted, fontSize: 12)),
            ])),
            const AccountButton(),
          ]),
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

  // ---------- Featured banner ----------
  Widget _featuredBanner() {
    final list = _bannerTracks;
    if (list.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(child: Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Column(children: [
        SizedBox(height: 152, child: PageView.builder(
          controller: _bannerCtrl,
          itemCount: list.length,
          onPageChanged: (i) => setState(() => _bannerPage = i),
          itemBuilder: (_, i) {
            final t = list[i];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: GestureDetector(
                onTap: () => playQueue(list, i),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(fit: StackFit.expand, children: [
                    // Fill the banner completely (no empty top/bottom space).
                    // The wide visuals are ~2.5:1, so at this banner height
                    // cover fills edge-to-edge with negligible cropping.
                    Builder(builder: (_) {
                      final img = t.bannerUrl ?? t.artworkUrl;
                      if (img == null) return const ColoredBox(color: kCard);
                      return Image.network(img, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => (t.artworkUrl != null)
                          ? Image.network(t.artworkUrl!, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                const ColoredBox(color: kCard))
                          : const ColoredBox(color: kCard));
                    }),
                    const DecoratedBox(decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xD9000000)]))),
                    Positioned(right: 14, top: 14, child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: kPrimary.withOpacity(0.92),
                        shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow,
                        color: Colors.white, size: 22))),
                    Positioned(left: 16, right: 16, bottom: 14,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('FEATURED', style: TextStyle(
                            color: kLight, fontSize: 11,
                            fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                          const SizedBox(height: 3),
                          Text(t.title, maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white,
                              fontSize: 19, fontWeight: FontWeight.w900,
                              height: 1.1)),
                        ])),
                  ]),
                ),
              ),
            );
          })),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(list.length, (i) => AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == _bannerPage ? 18 : 6, height: 6,
            decoration: BoxDecoration(
              color: i == _bannerPage ? kPrimary : kBorder,
              borderRadius: BorderRadius.circular(99))))),
      ])));
  }

  // ---------- Home ----------
  Widget _home() {
    final feat = _featured;
    final pop  = _mostPlayed;
    final all  = _sorted;
    return CustomScrollView(slivers: [
      _featuredBanner(),
      // Play all  +  [ Shuffle | Repeat ]
      SliverToBoxAdapter(child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
        child: Row(children: [
          Expanded(child: SizedBox(height: 46, child: ElevatedButton.icon(
            onPressed: _playAll,
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12))),
            icon: const Icon(Icons.play_arrow, color: Colors.white),
            label: const Text('Play all', style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700))))),
          const SizedBox(width: 10),
          const Expanded(child: ShuffleRepeatPill()),
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

  Future<void> _play() async {
    if (album.tracks.isEmpty) return;
    // When shuffle is on, begin from a RANDOM track of this album.
    final start = isShuffle.value ? Random().nextInt(album.tracks.length) : 0;
    await playQueue(album.tracks, start);
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
              Expanded(child: SizedBox(height: 46, child: ElevatedButton.icon(
                onPressed: _play,
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.play_arrow, color: Colors.white),
                label: const Text('Play all', style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700))))),
              const SizedBox(width: 10),
              const Expanded(child: ShuffleRepeatPill()),
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
        const SizedBox(height: 10),
        // Colorful animated sound-wave visualizer (Point 3). Sits ABOVE the
        // progress bar; the spacing below pushes the bar + controls down.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28),
          child: AudioWaveBar(height: 60)),
        const SizedBox(height: 18),
        const _ProgressBar(),
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
            ValueListenableBuilder<LoopMode>(valueListenable: repeatMode,
              builder: (_, m, __) => IconButton(
                icon: Icon(Icons.repeat_one,
                  color: m == LoopMode.one ? kLight : kMuted, size:26),
                onPressed: toggleRepeatOne))])),
        const SizedBox(height: 20)])));
}

// ---- Sound-wave visualizer (now-playing screen) ----
// A colorful, mirrored "equalizer" that DANCES while a track plays and rests
// when paused. Each bar's base height comes from the track's REAL SoundCloud
// waveform (so every song looks different and it never feels random), and a
// gentle per-bar oscillation makes the bars move with the music. Seeking is
// handled by the progress slider below — this is purely a visual.
class AudioWaveBar extends StatefulWidget {
  final double height;
  const AudioWaveBar({super.key, this.height = 60});
  @override
  State<AudioWaveBar> createState() => _AudioWaveBarState();
}

class _AudioWaveBarState extends State<AudioWaveBar>
    with SingleTickerProviderStateMixin {
  static const int _barCount = 48;
  List<double> _bars = const [];
  String? _loadedId;
  final Map<String, List<double>> _cache = {};
  late final AnimationController _anim;
  late final List<double> _phase;

  @override
  void initState() {
    super.initState();
    // Spread phases so neighbouring bars move at slightly different times,
    // giving an organic dance rather than one obvious repeating pulse.
    _phase = List.generate(_barCount, (i) => i * 0.55);
    _anim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1300))..repeat();
    currentTrack.addListener(_onTrack);
    _onTrack();
  }

  @override
  void dispose() {
    _anim.dispose();
    currentTrack.removeListener(_onTrack);
    super.dispose();
  }

  void _onTrack() {
    final t = currentTrack.value;
    if (t == null) {
      if (mounted) setState(() { _bars = const []; _loadedId = null; });
      return;
    }
    if (t.id == _loadedId) return;
    _loadedId = t.id;
    final cached = _cache[t.id];
    if (cached != null) {
      if (mounted) setState(() => _bars = cached);
      return;
    }
    if (mounted) setState(() => _bars = const []);   // baseline while loading
    _fetchWaveform(t);
  }

  Future<void> _fetchWaveform(SCTrack t) async {
    List<double> bars;
    final url = t.waveformUrl;
    if (url == null) {
      bars = _fallback(t.id);
    } else {
      try {
        final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final raw = (j is Map && j['samples'] is List)
            ? (j['samples'] as List) : const [];
          bars = raw.isEmpty ? _fallback(t.id) : _downsample(raw, _barCount);
        } else {
          bars = _fallback(t.id);
        }
      } catch (_) {
        bars = _fallback(t.id);
      }
    }
    _cache[t.id] = bars;
    if (mounted && _loadedId == t.id) setState(() => _bars = bars);
  }

  // Reduce SoundCloud's ~1800 samples down to _barCount bars (0..1). We take
  // the PEAK (max) of each bucket — averaging flattens the shape and makes it
  // look like a plain bar; peaks keep the characteristic waveform spikes.
  List<double> _downsample(List raw, int n) {
    double maxV = 1;
    for (final v in raw) {
      final d = (v is num) ? v.toDouble() : 0.0;
      if (d > maxV) maxV = d;
    }
    final out = <double>[];
    final per = raw.length / n;
    for (int i = 0; i < n; i++) {
      final start = (i * per).floor();
      final end = ((i + 1) * per).floor();
      double peak = 0;
      for (int k = start; k < end && k < raw.length; k++) {
        final v = raw[k];
        final d = (v is num) ? v.toDouble() : 0.0;
        if (d > peak) peak = d;
      }
      out.add((peak / maxV).clamp(0.06, 1.0).toDouble());
    }
    return out;
  }

  // Stable pseudo-waveform if a track has no waveform_url (rare).
  List<double> _fallback(String id) {
    final rnd = Random(id.hashCode);
    return List.generate(_barCount, (_) => 0.25 + rnd.nextDouble() * 0.7);
  }

  @override
  Widget build(BuildContext context) {
    final base = _bars.isEmpty ? _fallback(_loadedId ?? 'x') : _bars;
    return ValueListenableBuilder<bool>(
      valueListenable: isPlaying,
      builder: (_, playing, __) {
        CustomPaint frame(double tv) => CustomPaint(
          painter: _WavePainter(
            bars: base, phase: _phase, t: tv, playing: playing));
        return SizedBox(
          height: widget.height,
          width: double.infinity,
          // Repaint every frame only while playing; static (frozen) when paused.
          child: playing
            ? AnimatedBuilder(
                animation: _anim, builder: (_, __) => frame(_anim.value))
            : frame(_anim.value),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> bars;
  final List<double> phase;
  final double t;          // 0..1 animation clock
  final bool playing;
  _WavePainter({required this.bars, required this.phase,
    required this.t, required this.playing});

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    const gap = 3.0;
    final bw = (size.width - gap * (n - 1)) / n;
    final mid = size.height / 2;
    final clock = t * 2 * pi;
    for (int i = 0; i < n; i++) {
      final baseH = (size.height * 0.18) + bars[i] * (size.height * 0.82);
      // While playing, each bar dances between ~55% and 100% of its real
      // height; while paused it sits at full real height (frozen).
      final osc = playing
        ? (0.55 + 0.45 * (sin(clock + phase[i]) * 0.5 + 0.5))
        : 1.0;
      final h = baseH * osc;
      final x = i * (bw + gap);
      final hue = (262 + (i / n) * 130) % 360;   // violet -> pink -> orange
      final color =
        HSVColor.fromAHSV(playing ? 1.0 : 0.75, hue, 0.72, 1.0).toColor();
      // Mirrored around the centre line = clear "equalizer" look (not a bar).
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - h / 2, bw, h),
          Radius.circular(bw / 2)),
        Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
    old.t != t || old.playing != playing || !identical(old.bars, bars);
}

// Progress bar that scrubs smoothly WITHOUT hanging: while dragging it only
// moves the thumb locally (no seeks); it issues a single seek when released.
class _ProgressBar extends StatefulWidget {
  const _ProgressBar();
  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _drag;   // non-null while the user is dragging

  String _fmt(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (_, ps) {
        final pos = ps.data ?? Duration.zero;
        final tot = player.duration ?? Duration.zero;
        final live = tot.inMilliseconds > 0
          ? (pos.inMilliseconds / tot.inMilliseconds).clamp(0.0, 1.0)
          : 0.0;
        final value = _drag ?? live.toDouble();
        final shownPos = _drag != null
          ? Duration(milliseconds: (_drag! * tot.inMilliseconds).round())
          : pos;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: kPrimary, inactiveTrackColor: kBorder,
                thumbColor: kLight, overlayColor: kPrimary.withOpacity(0.2),
                trackHeight: 4),
              child: Slider(
                value: value,
                onChanged: (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  final ms = (v * (player.duration?.inMilliseconds ?? 0))
                    .round();
                  player.seek(Duration(milliseconds: ms));
                  setState(() => _drag = null);
                })),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(_fmt(shownPos),
                style: const TextStyle(color: kMuted, fontSize: 12)),
              Text(_fmt(tot),
                style: const TextStyle(color: kMuted, fontSize: 12)),
            ]),
          ]),
        );
      },
    );
  }
}

// ===========================================================================
// Videos (YouTube) — two channel tabs, video list, in-app player + comments
// ===========================================================================
class YTVideo {
  final String id, title;
  final String? thumb, published;
  const YTVideo({required this.id, required this.title,
    this.thumb, this.published});
  factory YTVideo.fromJson(Map<String, dynamic> j) => YTVideo(
    id: (j['id'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    thumb: j['thumb'] as String?,
    published: j['published'] as String?);
}

class YTChannel {
  final String title, handle;
  final String? avatar, subs;
  const YTChannel({required this.title, required this.handle,
    this.avatar, this.subs});
  factory YTChannel.fromJson(Map<String, dynamic> j) => YTChannel(
    title: (j['title'] ?? 'Channel').toString(),
    handle: (j['handle'] ?? '').toString(),
    avatar: j['avatar'] as String?,
    subs: j['subs']?.toString());
}

class VideoTab extends StatelessWidget {
  const VideoTab({super.key});
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg, elevation: 0,
          title: const Text('Videos',
            style: TextStyle(color: kOn, fontWeight: FontWeight.w800)),
          bottom: const TabBar(
            indicatorColor: kPrimary,
            labelColor: kLight, unselectedLabelColor: kMuted,
            labelStyle: TextStyle(fontWeight: FontWeight.w700),
            tabs: [Tab(text: 'Farooq Music'), Tab(text: 'Farooq')]),
        ),
        body: const TabBarView(children: [
          _ChannelVideos(channel: 'music'),
          _ChannelVideos(channel: 'personal'),
        ]),
      ),
    );
  }
}

class _ChannelVideos extends StatefulWidget {
  final String channel;
  const _ChannelVideos({required this.channel});
  @override
  State<_ChannelVideos> createState() => _ChannelVideosState();
}

class _ChannelVideosState extends State<_ChannelVideos>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  YTChannel? _ch;
  List<YTVideo> _videos = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final r = await http
        .get(Uri.parse('$kBaseUrl?action=videos&ch=${widget.channel}'))
        .timeout(const Duration(seconds: 15));
      final j = jsonDecode(r.body);
      if (j is Map && j['ok'] == true) {
        _ch = j['channel'] is Map
          ? YTChannel.fromJson(Map<String, dynamic>.from(j['channel'])) : null;
        _videos = ((j['videos'] as List?) ?? [])
          .map((e) => YTVideo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
        _error = null;
      } else {
        _error = (j is Map ? j['error']?.toString() : null) ?? 'Could not load';
      }
    } catch (_) {
      _error = 'Network error';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _fmtDate(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct',
      'Nov','Dec'];
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _fmtSubs(String s) {
    final n = int.tryParse(s) ?? 0;
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kPrimary));
    }
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: kMuted, size: 40),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center,
            style: const TextStyle(color: kMuted)),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _load,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: kPrimary)),
            child: const Text('Retry', style: TextStyle(color: kLight))),
        ])));
    }
    return RefreshIndicator(
      color: kPrimary, backgroundColor: kCard, onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: _videos.length + 1,
        itemBuilder: (_, i) =>
          i == 0 ? _header() : _videoCard(_videos[i - 1])),
    );
  }

  Widget _header() {
    final c = _ch;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        if (c?.avatar != null)
          CircleAvatar(radius: 26, backgroundColor: kCard,
            backgroundImage: NetworkImage(c!.avatar!))
        else
          const CircleAvatar(radius: 26, backgroundColor: kCard,
            child: Icon(Icons.smart_display, color: kPrimary)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(c?.title ?? 'Channel', maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kOn, fontSize: 17,
              fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text([
            if (c != null && c.handle.isNotEmpty) c.handle,
            if (c?.subs != null) '${_fmtSubs(c!.subs!)} subscribers',
          ].join('  ·  '),
            style: const TextStyle(color: kMuted, fontSize: 12)),
        ])),
        IconButton(
          icon: const Icon(Icons.open_in_new, color: kLight, size: 20),
          onPressed: () =>
            openUrl('https://www.youtube.com/${c?.handle ?? ''}')),
      ]),
    );
  }

  Widget _videoCard(YTVideo v) {
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
          VideoPlayerScreen(video: v, channelTitle: _ch?.title ?? ''))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(borderRadius: BorderRadius.circular(14),
            child: AspectRatio(aspectRatio: 16 / 9, child: Stack(
              fit: StackFit.expand, children: [
              v.thumb != null
                ? Image.network(v.thumb!, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const ColoredBox(color: kCard))
                : const ColoredBox(color: kCard),
              Center(child: Container(width: 52, height: 52,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow,
                  color: Colors.white, size: 30))),
            ]))),
          const SizedBox(height: 8),
          Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kOn, fontSize: 14,
              fontWeight: FontWeight.w600, height: 1.25)),
          const SizedBox(height: 2),
          Text(_fmtDate(v.published),
            style: const TextStyle(color: kMuted, fontSize: 11.5)),
        ]),
      ),
    );
  }
}

// In-app YouTube player: real iframe player (inline + fullscreen on rotate +
// native share), with the video title, action buttons and top comments below.
class VideoPlayerScreen extends StatefulWidget {
  final YTVideo video;
  final String channelTitle;
  const VideoPlayerScreen({super.key,
    required this.video, required this.channelTitle});
  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final YoutubePlayerController _controller;
  bool _loadingComments = true;
  List<Map<String, dynamic>> _comments = [];

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.video.id,
      autoPlay: true,
      params: const YoutubePlayerParams(showFullscreenButton: true));
    _loadComments();
  }

  Future<void> _loadComments() async {
    try {
      final r = await http
        .get(Uri.parse('$kBaseUrl?action=comments&v=${widget.video.id}'))
        .timeout(const Duration(seconds: 12));
      final j = jsonDecode(r.body);
      if (j is Map && j['ok'] == true) {
        _comments = ((j['comments'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingComments = false);
  }

  @override
  void dispose() { _controller.close(); super.dispose(); }

  void _share() => Share.share(
    '${widget.video.title}\nhttps://youtu.be/${widget.video.id}');

  @override
  Widget build(BuildContext context) {
    return YoutubePlayerScaffold(
      controller: _controller,
      aspectRatio: 16 / 9,
      builder: (context, player) => Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg, elevation: 0,
          iconTheme: const IconThemeData(color: kOn),
          title: const Text('Video',
            style: TextStyle(color: kOn, fontWeight: FontWeight.w700))),
        body: Column(children: [
          player,
          Expanded(child: ListView(padding: const EdgeInsets.all(16),
            children: [
              Text(widget.video.title,
                style: const TextStyle(color: kOn, fontSize: 16,
                  fontWeight: FontWeight.w800, height: 1.3)),
              const SizedBox(height: 4),
              Text(widget.channelTitle,
                style: const TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 12),
              Row(children: [
                _action(Icons.share, 'Share', _share),
                const SizedBox(width: 10),
                _action(Icons.open_in_new, 'YouTube',
                  () => openUrl('https://youtu.be/${widget.video.id}')),
              ]),
              const SizedBox(height: 18),
              const Text('COMMENTS', style: TextStyle(color: kLight,
                fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
              const SizedBox(height: 8),
              if (_loadingComments)
                const Padding(padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator(
                    color: kPrimary, strokeWidth: 2)))
              else if (_comments.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No comments to show.',
                    style: TextStyle(color: kMuted, fontSize: 13)))
              else
                ..._comments.map(_commentTile),
            ])),
        ]),
      ),
    );
  }

  Widget _action(IconData ic, String label, VoidCallback onTap) =>
    OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: kBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99))),
      icon: Icon(ic, color: kLight, size: 18),
      label: Text(label, style: const TextStyle(color: kLight)));

  Widget _commentTile(Map<String, dynamic> c) {
    final avatar = c['avatar']?.toString();
    final likes = (c['likes'] is int) ? c['likes'] as int : 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(radius: 16, backgroundColor: kCard,
          backgroundImage: avatar != null ? NetworkImage(avatar) : null,
          child: avatar == null
            ? const Icon(Icons.person, color: kMuted, size: 16) : null),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(c['author']?.toString() ?? '',
            style: const TextStyle(color: kLight, fontSize: 12.5,
              fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(c['text']?.toString() ?? '',
            style: const TextStyle(color: kOn, fontSize: 13, height: 1.3)),
          if (likes > 0) ...[
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.thumb_up_alt_outlined, color: kMuted, size: 12),
              const SizedBox(width: 4),
              Text('$likes', style: const TextStyle(color: kMuted, fontSize: 11)),
            ]),
          ],
        ])),
      ]),
    );
  }
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
          Image.network(
            'https://farooqmusic.com/farooq-music-logo.png',
            height: 64, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text('Farooq Music',
              style: TextStyle(color: kOn,
                fontSize: 22, fontWeight: FontWeight.w900))),
          const SizedBox(height: 12),
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
        // ---- Support ----
        _sectionTitle('SUPPORT'),
        _bigButton(Icons.favorite_outline, 'Support on PayPal',
          () => openUrl(
            'https://www.paypal.com/donate/?business=farooq2%40hotmail.com'
            '&item_name=Support+Farooq+Music&currency_code=USD')),
        const SizedBox(height: 6),
        Center(child: Text('farooq2@hotmail.com',
          style: TextStyle(color: kMuted.withOpacity(0.8), fontSize: 12))),
        const SizedBox(height: 24),
        Center(child: Text('Made with Suno AI · © Farooq Music',
          style: TextStyle(color: kMuted.withOpacity(0.7), fontSize: 11))),
      ])));
}
// ===========================================================================
// Account: avatar button in the Music header + full Account screen
// ===========================================================================

class AccountButton extends StatelessWidget {
  const AccountButton({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<User?>(
    valueListenable: authUser,
    builder: (_, user, __) => GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AccountScreen())),
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: kCard, shape: BoxShape.circle,
          border: Border.all(
            color: user == null ? kBorder : kPrimary, width: 1.5)),
        child: ClipOval(child: ValueListenableBuilder<String?>(
          valueListenable: avatarUrl,
          builder: (_, url, __) => (user != null && url != null)
            ? Image.network(url, width: 44, height: 44, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.person, color: kLight, size: 24))
            : Icon(user == null ? Icons.person_outline : Icons.person,
                color: user == null ? kMuted : kLight, size: 24))),
      )));
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action,
      {required String failMsg, String? successMsg}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (successMsg != null) _snack(successMsg);
    } on AuthException catch (e) {
      _snack('$failMsg: ${e.message}');
    } on SignInWithAppleAuthorizationException catch (e) {
      // User tapping "Cancel" on the Apple sheet is not an error.
      if (e.code != AuthorizationErrorCode.canceled) _snack(failMsg);
    } catch (e) {
      // Covers a cancelled Google sheet and any other failure.
      final s = e.toString().toLowerCase();
      if (!s.contains('cancel')) _snack(failMsg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: kOn)),
      duration: const Duration(seconds: 6),
      backgroundColor: kCard, behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(backgroundColor: kBg, elevation: 0,
      iconTheme: const IconThemeData(color: kOn),
      title: const Text('Account', style: TextStyle(
        color: kOn, fontSize: 17, fontWeight: FontWeight.w800))),
    body: ValueListenableBuilder<User?>(
      valueListenable: authUser,
      builder: (_, user, __) =>
        user == null ? _signedOut() : _signedIn(user)));

  // ---------- Signed-out: show the sign-in options ----------
  Widget _signedOut() => ListView(
    padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
    children: [
      Center(child: Container(
        width: 92, height: 92,
        decoration: BoxDecoration(shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.4),
            blurRadius: 28, spreadRadius: 2)]),
        child: ClipOval(child: Image.network(
          'https://farooqmusic.com/farooq-logo.png', fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(color: kCard,
            child: const Icon(Icons.music_note, color: kPrimary, size: 38)))))),
      const SizedBox(height: 18),
      const Text('Sign in to Farooq Music', textAlign: TextAlign.center,
        style: TextStyle(color: kOn, fontSize: 20, fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      const Text(
        'Create your own playlists and save music for offline listening. '
        'Those features are coming next — sign in now so your account is ready.',
        textAlign: TextAlign.center,
        style: TextStyle(color: kMuted, fontSize: 13, height: 1.5)),
      const SizedBox(height: 28),
      // Apple first (kept at least as prominent as Google, per App Store rules).
      _authButton(
        bg: Colors.black, fg: Colors.white,
        icon: const Icon(Icons.apple, color: Colors.white, size: 24),
        label: 'Sign in with Apple',
        onTap: () => _run(signInWithApple,
          failMsg: 'Apple sign-in failed', successMsg: 'Signed in')),
      const SizedBox(height: 12),
      _authButton(
        bg: Colors.white, fg: const Color(0xFF1f1f1f),
        icon: _googleG(),
        label: 'Sign in with Google',
        onTap: () => _run(signInWithGoogle,
          failMsg: 'Google sign-in failed', successMsg: 'Signed in')),
      const SizedBox(height: 22),
      if (_busy)
        const Center(child: SizedBox(width: 26, height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.6, color: kPrimary))),
      const SizedBox(height: 10),
      const Text('Guests can keep listening freely — sign-in is only needed '
        'for playlists and downloads.', textAlign: TextAlign.center,
        style: TextStyle(color: kMuted, fontSize: 11, height: 1.5)),
    ]);

  // ---------- Signed-in: profile + sign out ----------
  Widget _signedIn(User user) {
    final name = displayName(user);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final email = user.email;
    final provider = user.appMetadata['provider'];
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
      children: [
        Center(child: Opacity(
          opacity: _busy ? 0.6 : 1,
          child: GestureDetector(
            onTap: _busy
              ? null
              : () => _changePhoto(hasPhoto: avatarUrl.value != null),
            child: ValueListenableBuilder<String?>(
              valueListenable: avatarUrl,
              builder: (_, url, __) => Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 92, height: 92, alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: kCard,
                      border: Border.all(color: kPrimary, width: 2),
                      boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.35),
                        blurRadius: 24, spreadRadius: 1)]),
                    child: ClipOval(child: (url != null)
                      ? Image.network(url, width: 92, height: 92, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _initialCircle(initial))
                      : _initialCircle(initial))),
                  Positioned(right: -2, bottom: -2, child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: kPrimary, shape: BoxShape.circle,
                      border: Border.all(color: kBg, width: 2)),
                    child: const Icon(Icons.camera_alt,
                      color: Colors.white, size: 15))),
                ]))))),
        const SizedBox(height: 16),
        Text(name, textAlign: TextAlign.center, style: const TextStyle(
          color: kOn, fontSize: 19, fontWeight: FontWeight.w800)),
        if (email != null) ...[
          const SizedBox(height: 4),
          Text(email, textAlign: TextAlign.center,
            style: const TextStyle(color: kMuted, fontSize: 13)),
        ],
        const SizedBox(height: 10),
        Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: kPrimary.withOpacity(0.18),
            borderRadius: BorderRadius.circular(99)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.verified_user, color: kLight, size: 14),
            const SizedBox(width: 6),
            Text(
              provider is String && provider.isNotEmpty
                ? 'Signed in with ${provider[0].toUpperCase()}${provider.substring(1)}'
                : 'Signed in',
              style: const TextStyle(color: kLight, fontSize: 12,
                fontWeight: FontWeight.w600)),
          ]))),
        const SizedBox(height: 14),
        Center(child: TextButton.icon(
          onPressed: _busy
            ? null
            : () => _changePhoto(hasPhoto: avatarUrl.value != null),
          icon: const Icon(Icons.photo_camera_outlined, color: kLight, size: 18),
          label: const Text('Change photo', style: TextStyle(
            color: kLight, fontWeight: FontWeight.w700)))),
        const SizedBox(height: 30),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(signOutUser,
            failMsg: 'Sign out failed', successMsg: 'Signed out'),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: kBorder),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12))),
          icon: const Icon(Icons.logout, color: kMuted, size: 20),
          label: const Text('Sign out',
            style: TextStyle(color: kOn, fontWeight: FontWeight.w700))),
        const SizedBox(height: 18),
        if (_busy)
          const Center(child: SizedBox(width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: kPrimary))),
      ]);
  }

  Widget _authButton({required Color bg, required Color fg,
      required Widget icon, required String label,
      required VoidCallback onTap}) =>
    Opacity(opacity: _busy ? 0.6 : 1, child: Material(
      color: bg, borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _busy ? null : onTap,
        child: Container(height: 54, alignment: Alignment.center,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            icon, const SizedBox(width: 12),
            Text(label, style: TextStyle(color: fg, fontSize: 16,
              fontWeight: FontWeight.w600)),
          ])))));

  // A simple multi-colour Google "G" so we don't need an image asset.
  Widget _googleG() => Container(
    width: 24, height: 24, alignment: Alignment.center,
    child: const Text('G', style: TextStyle(
      color: Color(0xFF4285F4), fontSize: 20, fontWeight: FontWeight.w800,
      fontFamily: 'Roboto')));

  // The fallback circle showing the user's first initial (no photo set).
  Widget _initialCircle(String initial) => Container(
    width: 92, height: 92, alignment: Alignment.center, color: kCard,
    child: Text(initial, style: const TextStyle(
      color: kLight, fontSize: 38, fontWeight: FontWeight.w900)));

  // Bottom sheet: choose gallery / camera (and remove, if a photo exists),
  // then upload and update the avatar.
  Future<void> _changePhoto({required bool hasPhoto}) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(
            color: kBorder, borderRadius: BorderRadius.circular(99))),
          const SizedBox(height: 6),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: kLight),
            title: const Text('Choose from gallery',
              style: TextStyle(color: kOn, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, 'gallery')),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined, color: kLight),
            title: const Text('Take a photo',
              style: TextStyle(color: kOn, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, 'camera')),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFff6b6b)),
              title: const Text('Remove photo',
                style: TextStyle(color: Color(0xFFff6b6b),
                  fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(ctx, 'remove')),
          const SizedBox(height: 8),
        ])));
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (choice == 'remove') {
        await removeAvatar();
        _snack('Photo removed');
      } else {
        final ok = await pickAndUploadAvatar(
          choice == 'camera' ? ImageSource.camera : ImageSource.gallery);
        if (ok) _snack('Photo updated');
      }
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
