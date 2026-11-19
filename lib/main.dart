import 'dart:convert';
import 'dart:math';
import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppColors.load();
  await Notifier.init();
  runApp(RoutineLogApp());
}

// ───────────────────────── 알림 ─────────────────────────

// 앱이 꺼져 있을 때 알림 버튼 누르면 여기로 옴
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  await Notifier.init(background: true);
  await Notifier.handleAction(r);
}

class Notifier {
  static final plugin = FlutterLocalNotificationsPlugin();
  static final _rand = Random();

  // 단계별 엄마 잔소리 (여러 개 중 랜덤)
  static const stage1 = [
    // 순한 맛
    '약 먹을 시간이야~ 💊',
    '약 챙겨 먹자~ 물이랑 같이!',
    '잊지 말고 약 먹어~ 😊',
    '오늘도 약 잘 챙기자~',
  ];
  static const stage2 = [
    // 잔소리
    '아직도 안 먹었어? 엄마가 몇 번을 말해~',
    '약 먹으라니까~ 나중에 또 까먹는다!',
    '바쁜 건 알겠는데 약은 먹고 해!',
    '약 안 먹으면 엄마 속상하다~',
  ];
  static const stage3 = [
    // 사투리 꾸짖음
    '아따 아직도 안 묵었냐잉? 언능 묵어라!',
    '니 시방 약 안 묵고 뭐 한다냐잉~',
    '참말로 징하다잉~ 약 묵으랑께!',
    '오매 속 터져불겄네! 약부터 묵어!',
  ];

  // 단계 사이 간격 (분)
  static const stageOffsets = [0, 30, 60];

  static Future<void> init({bool background = false}) async {
    if (kIsWeb) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Seoul'));
    await plugin.initialize(
      InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: background ? null : _onForeground,
      onDidReceiveBackgroundNotificationResponse: background
          ? null
          : notificationTapBackground,
    );
  }

  // 앱 켜져 있을 때 알림(또는 버튼) 누르면
  static Future<void> _onForeground(NotificationResponse r) async {
    await handleAction(r);
    themeVersion.value++; // 오늘 화면으로 새로고침
  }

  // 알림 버튼(먹었어요/아직이에요/헷갈려요) → 기록 저장
  static Future<void> handleAction(NotificationResponse r) async {
    final action = r.actionId;
    final payload = r.payload;
    if (action == null || payload == null) return;

    // 🎒 챙김 알림의 '다 챙겼어요'
    if (action == 'checkAll' && payload.startsWith('check|')) {
      final date =
          DateTime.tryParse(payload.substring(6)) ??
          DateUtils.dateOnly(DateTime.now());
      final items = await CheckStore.loadItems();
      await CheckStore.saveChecked(date, items.toSet());
      await rescheduleAll();
      return;
    }

    final status = {
      'done': RecordStatus.done,
      'notYet': RecordStatus.notYet,
      'unsure': RecordStatus.unsure,
    }[action];
    if (status == null) return;
    final parts = payload.split('|'); // 복용id|날짜
    final date =
        DateTime.tryParse(parts.length > 1 ? parts[1] : '') ??
        DateUtils.dateOnly(DateTime.now());
    await Store.saveRaw(
      date,
      parts[0],
      DoseRecord(status, DateTime.now()).encode(),
    );
    await rescheduleAll(); // 먹었으면 남은 잔소리 취소 + 텀 약 예약
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android => plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  static Future<void> requestPermission() async {
    if (kIsWeb) return;
    await _android?.requestNotificationsPermission();
  }

  // 챙김 알림 (버튼 1개)
  static const _checkDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'check_channel',
      '챙김 알림',
      channelDescription: '나가기 전 챙길 것 알림',
      importance: Importance.max,
      priority: Priority.high,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'checkAll',
          '다 챙겼어요',
          cancelNotification: true,
        ),
      ],
    ),
  );

  static const checkMsgs = [
    '나가기 전에 다 챙겼냐~? 🎒',
    '또 두고 가지 말고 한 번 더 봐봐!',
    '아따 또 놓고 나갈라고? 챙겨라잉 🎒',
    '문 닫기 전에 가방 한 번 열어봐~',
  ];

  // 복용 알림 (버튼 3개 달림)
  static const _doseDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'dose_channel',
      '복용 알림',
      channelDescription: '약 먹을 시간 알림',
      importance: Importance.max,
      priority: Priority.high,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction('done', '먹었어요', cancelNotification: true),
        AndroidNotificationAction('notYet', '아직이에요', cancelNotification: true),
        AndroidNotificationAction('unsure', '헷갈려요', cancelNotification: true),
      ],
    ),
  );

  static String _body(DoseSlot slot) =>
      slot.meds.isEmpty ? slot.name : '${slot.name} · ${slot.meds.join(', ')}';

  // 알림 테스트 (10초 뒤)
  static Future<void> test() async {
    if (kIsWeb) return;
    await requestPermission();
    await plugin.zonedSchedule(
      999999,
      stage1[_rand.nextInt(stage1.length)],
      '알림 테스트예요 🌱 (버튼은 모양만 확인용)',
      tz.TZDateTime.now(tz.local).add(Duration(seconds: 10)),
      _doseDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  // 전체 알림 다시 맞추기 (기록 바뀔 때마다 호출)
  static Future<void> rescheduleAll() async {
    if (kIsWeb) return;
    await plugin.cancelAll();
    final slots = await Store.loadSlots();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (int i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final rec = await Store.loadRecord(today, slot.id);
      final doneToday = rec?.status == RecordStatus.done;

      if (!slot.isGap || i == 0) {
        // 시간 고정: 오늘부터 14일치 미리 예약 (오늘 먹었으면 오늘 건 빼기)
        for (int day = 0; day < 14; day++) {
          if (day == 0 && doneToday) continue;
          final d = today.add(Duration(days: day));
          final base = tz.TZDateTime(
            tz.local,
            d.year,
            d.month,
            d.day,
            slot.hour,
            slot.minute,
          );
          await _scheduleStages(i, day, base, slot);
        }
      } else {
        // 텀: 앞 복용을 먹었을 때만, 먹은 시간 + 텀으로 예약
        if (doneToday) continue;
        final prevRec = await Store.loadRecord(today, slots[i - 1].id);
        if (prevRec == null || prevRec.status != RecordStatus.done) continue;
        final t = prevRec.time.add(Duration(minutes: slot.gapMinutes));
        await _scheduleStages(i, 0, tz.TZDateTime.from(t, tz.local), slot);
      }
    }

    // 🎒 챙김 알림 (켜져 있을 때만, 오늘 다 챙겼으면 오늘 건 빼기)
    final (on, ch, cm) = await CheckStore.loadAlarm();
    final items = await CheckStore.loadItems();
    if (on && items.isNotEmpty) {
      final todayChecked = await CheckStore.loadChecked(today);
      final allDone = items.every(todayChecked.contains);
      final nowTz = tz.TZDateTime.now(tz.local);
      for (int day = 0; day < 14; day++) {
        if (day == 0 && allDone) continue;
        final d = today.add(Duration(days: day));
        final when = tz.TZDateTime(tz.local, d.year, d.month, d.day, ch, cm);
        if (!when.isAfter(nowTz)) continue;
        await plugin.zonedSchedule(
          900000 + day,
          checkMsgs[_rand.nextInt(checkMsgs.length)],
          items.join(' · '),
          when,
          _checkDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: 'check|${dateStr(d)}',
        );
      }
    }
  }

  static Future<void> _scheduleStages(
    int slotIdx,
    int day,
    tz.TZDateTime base,
    DoseSlot slot,
  ) async {
    final now = tz.TZDateTime.now(tz.local);
    final lists = [stage1, stage2, stage3];
    for (int s = 0; s < 3; s++) {
      final when = base.add(Duration(minutes: stageOffsets[s]));
      if (!when.isAfter(now)) continue;
      final msgs = lists[s];
      await plugin.zonedSchedule(
        slotIdx * 1000 + day * 10 + s,
        msgs[_rand.nextInt(msgs.length)],
        _body(slot),
        when,
        _doseDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: '${slot.id}|${dateStr(base)}',
      );
    }
  }
}

// 색상 팔레트 (앱에서 고를 수 있음)
class Palette {
  final String id;
  final String name;
  final Color cream, beige, pink, pinkSoft, brown, brownLight;
  String get icon => 'assets/theme/theme_$id.png';
  Palette(
    this.id,
    this.name,
    this.cream,
    this.beige,
    this.pink,
    this.pinkSoft,
    this.brown,
    this.brownLight,
  );
}

final palettes = [
  Palette(
    'purple',
    '라벤더',
    Color(0xFFFCF9F4),
    Color(0xFFECE5FA),
    Color(0xFFA58BEF),
    Color(0xFFE5DCFB),
    Color(0xFF2E2563),
    Color(0xFF857BAA),
  ),
  Palette(
    'pink',
    '벚꽃',
    Color(0xFFFFF8F0),
    Color(0xFFF7E4E0),
    Color(0xFFE8A5A5),
    Color(0xFFF7DCDC),
    Color(0xFF6B5146),
    Color(0xFFA48B7E),
  ),
  Palette(
    'mint',
    '민트',
    Color(0xFFF9FCF9),
    Color(0xFFE1F3EC),
    Color(0xFF6CC3A5),
    Color(0xFFD5EFE5),
    Color(0xFF23493F),
    Color(0xFF7A9C91),
  ),
  Palette(
    'sky',
    '하늘',
    Color(0xFFF9FBFE),
    Color(0xFFE3EEFB),
    Color(0xFF7FA8E8),
    Color(0xFFD9E6FA),
    Color(0xFF233A63),
    Color(0xFF7A8DAD),
  ),
  Palette(
    'latte',
    '라떼',
    Color(0xFFFFF9F2),
    Color(0xFFF3E6D8),
    Color(0xFFC9A27E),
    Color(0xFFEEDFCC),
    Color(0xFF5A4334),
    Color(0xFFA08B7A),
  ),
];

// 지금 쓰는 색 (이름은 예전 그대로, 고른 팔레트 색이 들어감)
class AppColors {
  static String currentId = 'purple';
  static Color cream = palettes[0].cream; // 배경
  static Color beige = palettes[0].beige; // 카드
  static Color pink = palettes[0].pink; // 포인트 (선택된 버튼)
  static Color pinkSoft = palettes[0].pinkSoft; // 연한 포인트 (기본 버튼)
  static Color brown = palettes[0].brown; // 글씨
  static Color brownLight = palettes[0].brownLight; // 연한 글씨

  static void apply(Palette p) {
    currentId = p.id;
    cream = p.cream;
    beige = p.beige;
    pink = p.pink;
    pinkSoft = p.pinkSoft;
    brown = p.brown;
    brownLight = p.brownLight;
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('theme') ?? 'purple';
    apply(palettes.firstWhere((p) => p.id == id, orElse: () => palettes[0]));
  }

  static Future<void> choose(Palette p) async {
    apply(p);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme', p.id);
    themeVersion.value++; // 앱 전체 색 다시 그리기
  }
}

final themeVersion = ValueNotifier<int>(0);

class RoutineLogApp extends StatelessWidget {
  RoutineLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: themeVersion,
      builder: (_, version, __) => MaterialApp(
        key: ValueKey(version),
        title: '루틴로그',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          scaffoldBackgroundColor: AppColors.cream,
          colorScheme: ColorScheme.fromSeed(seedColor: AppColors.pink),
          useMaterial3: true,
        ),
        home: TodayScreen(),
      ),
    );
  }
}

// ───────────────────────── 데이터 ─────────────────────────

enum RecordStatus { none, done, notYet, unsure }

String emojiOf(RecordStatus s) {
  switch (s) {
    case RecordStatus.done:
      return '💊';
    case RecordStatus.notYet:
      return '⏰';
    case RecordStatus.unsure:
      return '🤔';
    case RecordStatus.none:
      return '';
  }
}

String labelOf(RecordStatus s) {
  switch (s) {
    case RecordStatus.done:
      return '먹었어요';
    case RecordStatus.notYet:
      return '아직이에요';
    case RecordStatus.unsure:
      return '헷갈려요';
    case RecordStatus.none:
      return '미확인';
  }
}

// 복용 시간 하나 (같이 먹는 약 여러 개를 묶음)
// 예: 기본 복용 - 오전 9:00 - [혈압약, 유산균]
//     추가 복용 - 기본 복용 먹고 2시간 뒤 - [철분제]
class DoseSlot {
  final String id;
  final String name;
  final bool isGap; // true = 앞 복용 먹고 텀 두기, false = 시간 고정
  final int hour;
  final int minute;
  final int gapMinutes;
  final List<String> meds; // 같이 먹는 약 이름들

  DoseSlot({
    required this.id,
    required this.name,
    required this.isGap,
    this.hour = 9,
    this.minute = 0,
    this.gapMinutes = 120,
    this.meds = const [],
  });

  DoseSlot copyWith({
    String? name,
    bool? isGap,
    int? hour,
    int? minute,
    int? gapMinutes,
    List<String>? meds,
  }) => DoseSlot(
    id: id,
    name: name ?? this.name,
    isGap: isGap ?? this.isGap,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    gapMinutes: gapMinutes ?? this.gapMinutes,
    meds: meds ?? this.meds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isGap': isGap,
    'hour': hour,
    'minute': minute,
    'gapMinutes': gapMinutes,
    'meds': meds,
  };

  factory DoseSlot.fromJson(Map<String, dynamic> j) => DoseSlot(
    id: j['id'],
    name: j['name'],
    isGap: j['isGap'] ?? false,
    hour: j['hour'] ?? 9,
    minute: j['minute'] ?? 0,
    gapMinutes: j['gapMinutes'] ?? 120,
    meds: List<String>.from(j['meds'] ?? []),
  );
}

// 하루 기록 하나 (상태 + 시간)
class DoseRecord {
  final RecordStatus status;
  final DateTime time;
  DoseRecord(this.status, this.time);

  String encode() => '${status.name}|${time.toIso8601String()}';

  static DoseRecord? decode(String? raw) {
    if (raw == null) return null;
    final p = raw.split('|');
    final s = RecordStatus.values.firstWhere(
      (e) => e.name == p[0],
      orElse: () => RecordStatus.none,
    );
    final t = p.length > 1 ? DateTime.tryParse(p[1]) : null;
    if (t == null) return null;
    return DoseRecord(s, t);
  }
}

String timeText(DateTime t) => timeTextHM(t.hour, t.minute);

String timeTextHM(int h, int m) {
  final ampm = h < 12 ? '오전' : '오후';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$ampm $h12:${m.toString().padLeft(2, '0')}';
}

String gapText(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h > 0 && m > 0) return '$h시간 $m분';
  if (h > 0) return '$h시간';
  return '$m분';
}

String dateStr(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String recordKey(DateTime d, String slotId) => 'dose_${dateStr(d)}_$slotId';

// ───────────────────────── 컨디션 ─────────────────────────

final moods = [
  ('assets/mood/mood_0.png', '최고'),
  ('assets/mood/mood_1.png', '좋음'),
  ('assets/mood/mood_2.png', '보통'),
  ('assets/mood/mood_3.png', '별로'),
  ('assets/mood/mood_4.png', '아픔'),
];

// 컨디션 그림 (기록 없으면 📝)
Widget moodImage(MoodRecord? m, double size) {
  if (m == null) return Text('📝', style: TextStyle(fontSize: size * 0.85));
  return Image.asset(m.image, width: size, height: size);
}

class MoodRecord {
  final int level; // moods 번호
  final String memo;
  MoodRecord(this.level, this.memo);

  String get image => moods[level].$1;
  String get label => moods[level].$2;
}

class MoodStore {
  static String _key(DateTime d) => 'mood_${dateStr(d)}';

  static Future<MoodRecord?> load(DateTime d) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(d));
    if (raw == null) return null;
    final j = jsonDecode(raw);
    final level = (j['level'] as int).clamp(0, moods.length - 1);
    return MoodRecord(level, j['memo'] ?? '');
  }

  static Future<void> save(DateTime d, MoodRecord? m) async {
    final prefs = await SharedPreferences.getInstance();
    if (m == null) {
      await prefs.remove(_key(d));
    } else {
      await prefs.setString(
        _key(d),
        jsonEncode({'level': m.level, 'memo': m.memo}),
      );
    }
  }
}

// 챙김 체크 (챙길 목록 + 날짜별 체크한 것)
class CheckStore {
  static const defaults = ['폰', '지갑', '열쇠', '약', '이어폰'];

  static Future<List<String>> loadItems() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('check_items') ?? List<String>.from(defaults);
  }

  static Future<void> saveItems(List<String> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('check_items', items);
  }

  // 챙김 알림 (켜짐, 시, 분)
  static Future<(bool, int, int)> loadAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getBool('check_alarm_on') ?? false,
      prefs.getInt('check_alarm_h') ?? 8,
      prefs.getInt('check_alarm_m') ?? 30,
    );
  }

  static Future<void> saveAlarm(bool on, int h, int m) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('check_alarm_on', on);
    await prefs.setInt('check_alarm_h', h);
    await prefs.setInt('check_alarm_m', m);
  }

  static Future<Set<String>> loadChecked(DateTime d) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('check_${dateStr(d)}') ?? []).toSet();
  }

  static Future<void> saveChecked(DateTime d, Set<String> checked) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('check_${dateStr(d)}', checked.toList());
  }
}

// 생리 기록 (날짜별 켜기/끄기)
class PeriodStore {
  static String _key(DateTime d) => 'period_${dateStr(d)}';

  static Future<bool> isOn(DateTime d) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(d)) ?? false;
  }

  static Future<void> set(DateTime d, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    if (on) {
      await prefs.setBool(_key(d), true);
    } else {
      await prefs.remove(_key(d));
    }
  }

  // 가장 최근 생리 기간 (시작일, 마지막 날) - 최근 120일 안에서 찾기
  static Future<(DateTime, DateTime)?> lastPeriod() async {
    var d = DateUtils.dateOnly(DateTime.now());
    for (int i = 0; i < 120; i++) {
      if (await isOn(d)) {
        final end = d; // 제일 최근에 기록된 날 = 마지막 날
        // 연속된 날 거슬러 올라가서 첫날 찾기
        while (await isOn(d.subtract(const Duration(days: 1)))) {
          d = d.subtract(const Duration(days: 1));
        }
        return (d, end);
      }
      d = d.subtract(const Duration(days: 1));
    }
    return null;
  }
}

// 컨디션 기록 창 (저장/삭제하면 true)
Future<bool> showMoodEditor(BuildContext context, DateTime date) async {
  final existing = await MoodStore.load(date);
  int? level = existing?.level;
  final memoCtrl = TextEditingController(text: existing?.memo ?? '');
  bool period = await PeriodStore.isOn(date);
  bool periodChanged = false;
  if (!context.mounted) return false;

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.cream,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          MediaQuery.of(ctx).viewInsets.bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${date.month}월 ${date.day}일 컨디션',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.brown,
              ),
            ),
            SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (int i = 0; i < moods.length; i++)
                  GestureDetector(
                    onTap: () => setSheet(() => level = i),
                    child: AnimatedContainer(
                      duration: Duration(milliseconds: 150),
                      width: 58,
                      padding: EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: level == i ? AppColors.pinkSoft : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: level == i ? AppColors.pink : AppColors.beige,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        children: [
                          Image.asset(moods[i].$1, width: 34, height: 34),
                          SizedBox(height: 4),
                          Text(
                            moods[i].$2,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.brown,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 14),
            // 생리 기록 (누르면 바로 저장)
            GestureDetector(
              onTap: () async {
                period = !period;
                periodChanged = true;
                await PeriodStore.set(date, period);
                setSheet(() {});
              },
              child: AnimatedContainer(
                duration: Duration(milliseconds: 150),
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: period ? Color(0xFFFFE3E6) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: period ? Color(0xFFF08A99) : AppColors.beige,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Text('🩸', style: TextStyle(fontSize: 18)),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        period ? '생리 중이에요' : '생리 기록하기',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.brown,
                        ),
                      ),
                    ),
                    Icon(
                      period
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: period ? Color(0xFFF08A99) : AppColors.brownLight,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 14),
            TextField(
              controller: memoCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: '한 줄 메모 (예: 두통 있음, 잠 잘 잠)',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            SizedBox(height: 20),
            Row(
              children: [
                if (existing != null) ...[
                  TextButton(
                    onPressed: () async {
                      await MoodStore.save(date, null);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    },
                    child: Text(
                      '지우기',
                      style: TextStyle(color: AppColors.brownLight),
                    ),
                  ),
                  SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.pink,
                      padding: EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: level == null
                        ? null
                        : () async {
                            await MoodStore.save(
                              date,
                              MoodRecord(level!, memoCtrl.text.trim()),
                            );
                            if (ctx.mounted) Navigator.pop(ctx, true);
                          },
                    child: Text('저장하기', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result == true || periodChanged;
}

// ───────────────────────── 색 고르기 화면 ─────────────────────────

class ThemeScreen extends StatelessWidget {
  ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.cream,
        foregroundColor: AppColors.brown,
        title: Text('색상 고르기', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          for (final p in palettes)
            GestureDetector(
              onTap: () => AppColors.choose(p),
              child: Container(
                margin: EdgeInsets.only(bottom: 12),
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: p.cream,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppColors.currentId == p.id ? p.pink : p.beige,
                    width: AppColors.currentId == p.id ? 2.5 : 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Image.asset(p.icon, width: 40, height: 40),
                    SizedBox(width: 12),
                    for (final c in [p.pink, p.pinkSoft, p.beige, p.brown])
                      Container(
                        width: 26,
                        height: 26,
                        margin: EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: p.brown,
                        ),
                      ),
                    ),
                    if (AppColors.currentId == p.id)
                      Icon(Icons.check_circle, color: p.pink),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 저장소
class Store {
  static Future<List<DoseSlot>> loadSlots() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('slots');
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      return list.map((e) => DoseSlot.fromJson(e)).toList();
    }
    // 이전 버전(약 하나씩 등록) 데이터가 있으면 옮겨오기
    final old = prefs.getString('medicines');
    if (old != null) {
      final list = jsonDecode(old) as List;
      final slots = list
          .map(
            (j) => DoseSlot(
              id: j['id'],
              name: j['name'],
              isGap: j['isGap'] ?? false,
              hour: j['hour'] ?? 9,
              minute: j['minute'] ?? 0,
              gapMinutes: j['gapMinutes'] ?? 120,
              meds: [j['name']],
            ),
          )
          .toList();
      await saveSlots(slots);
      return slots;
    }
    return [];
  }

  static Future<void> saveSlots(List<DoseSlot> slots) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'slots',
      jsonEncode(slots.map((m) => m.toJson()).toList()),
    );
  }

  static Future<DoseRecord?> loadRecord(DateTime d, String slotId) async {
    final prefs = await SharedPreferences.getInstance();
    return DoseRecord.decode(prefs.getString(recordKey(d, slotId)));
  }

  static Future<void> saveRaw(DateTime d, String slotId, String? raw) async {
    final prefs = await SharedPreferences.getInstance();
    if (raw == null) {
      await prefs.remove(recordKey(d, slotId));
    } else {
      await prefs.setString(recordKey(d, slotId), raw);
    }
  }

  static Future<String?> loadRaw(DateTime d, String slotId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(recordKey(d, slotId));
  }
}

// 약 이름 칩
Widget medChip(String name, {VoidCallback? onDelete}) {
  return Container(
    padding: EdgeInsets.fromLTRB(12, 6, onDelete == null ? 12 : 4, 6),
    decoration: BoxDecoration(
      color: AppColors.cream,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.beige),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, style: TextStyle(fontSize: 13, color: AppColors.brown)),
        if (onDelete != null)
          GestureDetector(
            onTap: onDelete,
            child: Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.close, size: 16, color: AppColors.brownLight),
            ),
          ),
      ],
    ),
  );
}

// ───────────────────────── 오늘 화면 ─────────────────────────

class TodayScreen extends StatefulWidget {
  TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> with WidgetsBindingObserver {
  List<DoseSlot> slots = [];
  Map<String, DoseRecord> records = {};
  MoodRecord? mood;
  bool periodToday = false;
  List<String> checkItems = [];
  Set<String> checked = {};
  bool loading = true;

  DateTime get today => DateUtils.dateOnly(DateTime.now());

  String get todayLabel {
    final now = DateTime.now();
    final weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return '${now.month}월 ${now.day}일 (${weekdays[now.weekday - 1]})';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Notifier.requestPermission();
    loadAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 알림에서 기록하고 앱으로 돌아오면 바로 반영
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) loadAll();
  }

  Future<void> loadAll() async {
    final s = await Store.loadSlots();
    final r = <String, DoseRecord>{};
    for (final slot in s) {
      final rec = await Store.loadRecord(today, slot.id);
      if (rec != null) r[slot.id] = rec;
    }
    final m = await MoodStore.load(today);
    final pd = await PeriodStore.isOn(today);
    final ci = await CheckStore.loadItems();
    final cc = await CheckStore.loadChecked(today);
    setState(() {
      slots = s;
      records = r;
      mood = m;
      periodToday = pd;
      checkItems = ci;
      checked = cc.where(ci.contains).toSet();
      loading = false;
    });
    Notifier.rescheduleAll();
  }

  // 언제 먹을지 안내 문구
  String scheduleText(int index) {
    final slot = slots[index];
    if (!slot.isGap || index == 0) {
      return timeTextHM(slot.hour, slot.minute);
    }
    final prev = slots[index - 1];
    final prevRec = records[prev.id];
    if (prevRec != null && prevRec.status == RecordStatus.done) {
      final target = prevRec.time.add(Duration(minutes: slot.gapMinutes));
      return '${timeText(target)} 예정';
    }
    return "'${prev.name}' 먹고 ${gapText(slot.gapMinutes)} 뒤";
  }

  int get doneCount =>
      records.values.where((r) => r.status == RecordStatus.done).length;

  Future<void> onTapStatus(DoseSlot slot, RecordStatus newStatus) async {
    final current = records[slot.id]?.status ?? RecordStatus.none;
    if (newStatus == current) return;

    if (current != RecordStatus.none) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(
            '기록을 바꿀까요?',
            style: TextStyle(
              color: AppColors.brown,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            "'${slot.name}'은(는) 이미 '${labelOf(current)}'로 기록했어요.\n'${labelOf(newStatus)}'(으)로 바꿀까요?",
            style: TextStyle(color: AppColors.brown, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                '그대로 둘래요',
                style: TextStyle(color: AppColors.brownLight),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                '바꿀래요',
                style: TextStyle(
                  color: AppColors.pink,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final rec = DoseRecord(newStatus, DateTime.now());
    await Store.saveRaw(today, slot.id, rec.encode());
    setState(() => records[slot.id] = rec);
    Notifier.rescheduleAll();
  }

  Future<void> openManage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SlotsScreen()),
    );
    loadAll();
  }

  Widget headerButton(String emoji, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.beige,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(emoji, style: TextStyle(fontSize: 22)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '루틴로그',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: AppColors.brown,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        todayLabel,
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.brownLight,
                        ),
                      ),
                    ],
                  ),
                ),
                headerButton('🎨', () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ThemeScreen()),
                  );
                }),
                SizedBox(width: 8),
                headerButton('💊', openManage),
                SizedBox(width: 8),
                headerButton('📅', () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => CalendarScreen()),
                  );
                  loadAll();
                }),
              ],
            ),
            SizedBox(height: 24),
            if (loading)
              SizedBox()
            else if (slots.isEmpty)
              _emptyCard()
            else ...[
              Container(
                padding: EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: AppColors.beige,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  children: [
                    Image.asset(
                      doneCount == 0
                          ? 'assets/mood/cup_empty.png' // 아직 하나도 안 먹음
                          : doneCount == slots.length
                          ? 'assets/mood/cup_full.png' // 다 먹음
                          : 'assets/mood/cup_half.png', // 일부만 먹음
                      width: 72,
                      height: 72,
                    ),
                    SizedBox(height: 6),
                    Text(
                      doneCount == slots.length
                          ? '오늘 다 챙겼어요 💜'
                          : '오늘 ${slots.length}번 중 $doneCount번 챙겼어요',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.brown,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              for (int i = 0; i < slots.length; i++) _slotCard(i),
            ],
            if (!loading) ...[
              SizedBox(height: 6),
              _checkCard(),
              SizedBox(height: 14),
              _moodCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyCard() {
    return GestureDetector(
      onTap: openManage,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 40, horizontal: 20),
        decoration: BoxDecoration(
          color: AppColors.beige,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          children: [
            Text('🌱', style: TextStyle(fontSize: 52)),
            SizedBox(height: 12),
            Text(
              '아직 복용 시간이 없어요',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.brown,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '눌러서 기본 복용 시간 정하기',
              style: TextStyle(fontSize: 14, color: AppColors.brownLight),
            ),
          ],
        ),
      ),
    );
  }

  // 🎒 챙김 체크 카드
  Widget _checkCard() {
    final done = checkItems.isNotEmpty && checked.length == checkItems.length;
    return Container(
      padding: EdgeInsets.fromLTRB(18, 12, 8, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: done ? AppColors.pink : AppColors.beige,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('🎒', style: TextStyle(fontSize: 22)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '오늘 챙김',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.brown,
                  ),
                ),
              ),
              Text(
                '${checked.length}/${checkItems.length}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.brownLight,
                ),
              ),
              IconButton(
                tooltip: '챙길 것 편집',
                icon: Icon(
                  Icons.edit_outlined,
                  size: 20,
                  color: AppColors.brownLight,
                ),
                onPressed: openCheckEditor,
              ),
            ],
          ),
          if (checkItems.isEmpty)
            Text(
              '연필 눌러서 챙길 거 추가하기',
              style: TextStyle(fontSize: 14, color: AppColors.brownLight),
            )
          else
            Padding(
              padding: EdgeInsets.only(right: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in checkItems)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          checked.contains(item)
                              ? checked.remove(item)
                              : checked.add(item);
                        });
                        CheckStore.saveChecked(
                          today,
                          checked,
                        ).then((_) => Notifier.rescheduleAll());
                      },
                      child: AnimatedContainer(
                        duration: Duration(milliseconds: 150),
                        padding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: checked.contains(item)
                              ? AppColors.pink
                              : AppColors.pinkSoft,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              checked.contains(item)
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: checked.contains(item)
                                  ? Colors.white
                                  : AppColors.brownLight,
                            ),
                            SizedBox(width: 6),
                            Text(
                              item,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: checked.contains(item)
                                    ? Colors.white
                                    : AppColors.brown,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (done) ...[
            SizedBox(height: 12),
            Text(
              '다 챙겼어요! 이제 출발~ 🚶',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.pink,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 챙길 목록 편집 창
  Future<void> openCheckEditor() async {
    final items = List<String>.from(checkItems);
    final ctrl = TextEditingController();
    var (alarmOn, alarmH, alarmM) = await CheckStore.loadAlarm();
    if (!mounted) return;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.cream,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void add() {
            final t = ctrl.text.trim();
            if (t.isEmpty || items.contains(t)) return;
            setSheet(() {
              items.add(t);
              ctrl.clear();
            });
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              MediaQuery.of(ctx).viewInsets.bottom + 28,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🎒 챙길 것',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.brown,
                  ),
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ctrl,
                        onSubmitted: (_) => add(),
                        decoration: InputDecoration(
                          hintText: '예: 사원증, 우산, 텀블러',
                          filled: true,
                          fillColor: Colors.white,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    GestureDetector(
                      onTap: add,
                      child: Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.pink,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.add, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 14),
                if (items.isEmpty)
                  Text(
                    '아직 없어요',
                    style: TextStyle(fontSize: 13, color: AppColors.brownLight),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final it in items)
                        medChip(
                          it,
                          onDelete: () => setSheet(() => items.remove(it)),
                        ),
                    ],
                  ),
                SizedBox(height: 18),
                // 🔔 나가기 전 알림
                Container(
                  padding: EdgeInsets.fromLTRB(16, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Text('🔔', style: TextStyle(fontSize: 18)),
                      SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: !alarmOn
                              ? null
                              : () async {
                                  final t = await showTimePicker(
                                    context: ctx,
                                    initialTime: TimeOfDay(
                                      hour: alarmH,
                                      minute: alarmM,
                                    ),
                                  );
                                  if (t != null) {
                                    setSheet(() {
                                      alarmH = t.hour;
                                      alarmM = t.minute;
                                    });
                                  }
                                },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '나가기 전 알림',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.brown,
                                ),
                              ),
                              Text(
                                alarmOn
                                    ? '매일 ${timeTextHM(alarmH, alarmM)} (눌러서 변경)'
                                    : '꺼져 있어요',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.brownLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Switch(
                        value: alarmOn,
                        activeColor: AppColors.pink,
                        onChanged: (v) => setSheet(() => alarmOn = v),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.pink,
                      padding: EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      add(); // 입력칸에 남은 것도 추가
                      Navigator.pop(ctx, true);
                    },
                    child: Text('저장하기', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (saved == true) {
      await CheckStore.saveItems(items);
      await CheckStore.saveAlarm(alarmOn, alarmH, alarmM);
      checked = checked.where(items.contains).toSet();
      await CheckStore.saveChecked(today, checked);
      setState(() => checkItems = items);
      Notifier.rescheduleAll();
    }
  }

  Widget _moodCard() {
    return GestureDetector(
      onTap: () async {
        if (await showMoodEditor(context, today)) loadAll();
      },
      child: Container(
        padding: EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.beige,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            moodImage(mood, 42),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mood == null ? '오늘 컨디션은 어때요?' : '오늘 컨디션 · ${mood!.label}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.brown,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    (periodToday ? '🩸 생리 중 · ' : '') +
                        (mood == null
                            ? '눌러서 기록하기'
                            : (mood!.memo.isEmpty ? '메모 없음' : mood!.memo)),
                    style: TextStyle(fontSize: 14, color: AppColors.brownLight),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.brownLight),
          ],
        ),
      ),
    );
  }

  Widget _slotCard(int i) {
    final slot = slots[i];
    final rec = records[slot.id];
    final status = rec?.status ?? RecordStatus.none;

    return Container(
      margin: EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: status == RecordStatus.done ? AppColors.pink : AppColors.beige,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                status == RecordStatus.none ? '💊' : emojiOf(status),
                style: TextStyle(fontSize: 22),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  slot.name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.brown,
                  ),
                ),
              ),
              if (rec != null)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.cream,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${timeText(rec.time)} 기록',
                    style: TextStyle(fontSize: 12, color: AppColors.brownLight),
                  ),
                ),
            ],
          ),
          SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.only(left: 30),
            child: Text(
              '🕐 ${scheduleText(i)}',
              style: TextStyle(fontSize: 14, color: AppColors.brownLight),
            ),
          ),
          if (slot.meds.isNotEmpty) ...[
            SizedBox(height: 10),
            Padding(
              padding: EdgeInsets.only(left: 30),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: slot.meds.map((m) => medChip(m)).toList(),
              ),
            ),
          ],
          SizedBox(height: 14),
          Row(
            children: [
              for (final s in [
                RecordStatus.done,
                RecordStatus.notYet,
                RecordStatus.unsure,
              ]) ...[
                Expanded(
                  child: _SmallButton(
                    label: labelOf(s),
                    selected: status == s,
                    onTap: () => onTapStatus(slot, s),
                  ),
                ),
                if (s != RecordStatus.unsure) SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SmallButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: selected ? AppColors.pink : AppColors.pinkSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.brown,
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 복용 관리 화면 ─────────────────────────

class SlotsScreen extends StatefulWidget {
  SlotsScreen({super.key});

  @override
  State<SlotsScreen> createState() => _SlotsScreenState();
}

class _SlotsScreenState extends State<SlotsScreen> {
  List<DoseSlot> slots = [];

  @override
  void initState() {
    super.initState();
    Store.loadSlots().then((s) => setState(() => slots = s));
  }

  String describe(int i) {
    final s = slots[i];
    if (!s.isGap || i == 0) return '매일 ${timeTextHM(s.hour, s.minute)}';
    return "'${slots[i - 1].name}' 먹고 ${gapText(s.gapMinutes)} 뒤";
  }

  Future<void> save() async {
    // 첫 번째는 텀 방식일 수 없으니 시간 고정으로
    if (slots.isNotEmpty && slots[0].isGap) {
      slots[0] = slots[0].copyWith(isGap: false);
    }
    setState(() {});
    await Store.saveSlots(slots);
  }

  Future<void> deleteSlot(int i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.cream,
        title: Text(
          "'${slots[i].name}' 지울까요?",
          style: TextStyle(color: AppColors.brown),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('취소', style: TextStyle(color: AppColors.brownLight)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('지울래요', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    slots.removeAt(i);
    await save();
  }

  // 추가(index == null) 또는 수정(index 있음)
  Future<void> openEditor({int? index}) async {
    final editing = index != null ? slots[index] : null;
    final isFirst = (index ?? slots.length) == 0;
    final prevName = isFirst ? '' : slots[(index ?? slots.length) - 1].name;

    final nameCtrl = TextEditingController(
      text: editing?.name ?? (isFirst ? '기본 복용' : '추가 복용 ${slots.length}'),
    );
    final medCtrl = TextEditingController();
    bool isGap = editing?.isGap ?? !isFirst;
    if (isFirst) isGap = false;
    TimeOfDay time = TimeOfDay(
      hour: editing?.hour ?? 9,
      minute: editing?.minute ?? 0,
    );
    int gapTotal = editing?.gapMinutes ?? 120;
    int gapH = gapTotal ~/ 60;
    int gapM = (gapTotal % 60) ~/ 10 * 10;
    final meds = List<String>.from(editing?.meds ?? []);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.cream,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void addMed() {
            final t = medCtrl.text.trim();
            if (t.isEmpty) return;
            setSheet(() {
              meds.add(t);
              medCtrl.clear();
            });
          }

          InputDecoration box(String hint) => InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: Colors.white,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          );

          final label = TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.brownLight,
          );

          return Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              MediaQuery.of(ctx).viewInsets.bottom + 28,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    editing == null ? '복용 시간 추가' : '복용 시간 수정',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.brown,
                    ),
                  ),
                  SizedBox(height: 18),

                  Text('이름', style: label),
                  SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: box('예: 아침, 점심 후'),
                  ),
                  SizedBox(height: 18),

                  Text('언제 먹어요?', style: label),
                  SizedBox(height: 6),
                  if (!isFirst)
                    Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: Text("'$prevName' 먹고 텀"),
                            selected: isGap,
                            selectedColor: AppColors.pinkSoft,
                            onSelected: (_) => setSheet(() => isGap = true),
                          ),
                          ChoiceChip(
                            label: Text('시간 고정'),
                            selected: !isGap,
                            selectedColor: AppColors.pinkSoft,
                            onSelected: (_) => setSheet(() => isGap = false),
                          ),
                        ],
                      ),
                    ),
                  if (!isGap)
                    GestureDetector(
                      onTap: () async {
                        final t = await showTimePicker(
                          context: ctx,
                          initialTime: time,
                        );
                        if (t != null) setSheet(() => time = t);
                      },
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '🕐 매일 ${timeTextHM(time.hour, time.minute)}  (눌러서 변경)',
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.brown,
                          ),
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          DropdownButton<int>(
                            value: gapH,
                            underline: SizedBox(),
                            items: List.generate(
                              13,
                              (h) => DropdownMenuItem(
                                value: h,
                                child: Text('$h시간'),
                              ),
                            ),
                            onChanged: (v) => setSheet(() => gapH = v!),
                          ),
                          SizedBox(width: 12),
                          DropdownButton<int>(
                            value: gapM,
                            underline: SizedBox(),
                            items: [0, 10, 20, 30, 40, 50]
                                .map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text('$m분'),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setSheet(() => gapM = v!),
                          ),
                          SizedBox(width: 8),
                          Text('뒤', style: TextStyle(color: AppColors.brown)),
                        ],
                      ),
                    ),
                  SizedBox(height: 18),

                  Text('같이 먹는 약', style: label),
                  SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: medCtrl,
                          decoration: box('약 이름 쓰고 + 누르기'),
                          onSubmitted: (_) => addMed(),
                        ),
                      ),
                      SizedBox(width: 8),
                      GestureDetector(
                        onTap: addMed,
                        child: Container(
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.pink,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(Icons.add, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),
                  if (meds.isEmpty)
                    Text(
                      '아직 약이 없어요',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.brownLight,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (int k = 0; k < meds.length; k++)
                          medChip(
                            meds[k],
                            onDelete: () => setSheet(() => meds.removeAt(k)),
                          ),
                      ],
                    ),
                  SizedBox(height: 24),

                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.pink,
                        padding: EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () {
                        addMed(); // 입력칸에 남은 약도 같이 추가
                        if (nameCtrl.text.trim().isEmpty) return;
                        if (isGap && gapH == 0 && gapM == 0) return;
                        final slot = DoseSlot(
                          id:
                              editing?.id ??
                              DateTime.now().millisecondsSinceEpoch.toString(),
                          name: nameCtrl.text.trim(),
                          isGap: isGap,
                          hour: time.hour,
                          minute: time.minute,
                          gapMinutes: gapH * 60 + gapM,
                          meds: meds,
                        );
                        if (index != null) {
                          slots[index] = slot;
                        } else {
                          slots.add(slot);
                        }
                        Navigator.pop(ctx, true);
                      },
                      child: Text(
                        editing == null ? '추가하기' : '저장하기',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (saved == true) await save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.cream,
        foregroundColor: AppColors.brown,
        title: Text('복용 관리', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () async {
              await Notifier.test();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: AppColors.brown,
                  content: Text('10초 뒤에 테스트 알림이 와요! 앱 닫아도 돼요'),
                ),
              );
            },
            child: Text('🔔 알림 테스트', style: TextStyle(color: AppColors.brown)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.pink,
        foregroundColor: Colors.white,
        onPressed: () => openEditor(),
        icon: Icon(Icons.add),
        label: Text(slots.isEmpty ? '기본 복용 시간 정하기' : '복용 시간 추가'),
      ),
      body: slots.isEmpty
          ? Center(
              child: Text(
                '먼저 기본 복용 시간을 정해요',
                style: TextStyle(color: AppColors.brownLight),
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 100),
              itemCount: slots.length,
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => openEditor(index: i),
                child: Container(
                  margin: EdgeInsets.only(bottom: 12),
                  padding: EdgeInsets.fromLTRB(18, 14, 8, 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.pink,
                          ),
                        ),
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              slots[i].name,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: AppColors.brown,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              describe(i),
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.brownLight,
                              ),
                            ),
                            if (slots[i].meds.isNotEmpty) ...[
                              SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: slots[i].meds
                                    .map((m) => medChip(m))
                                    .toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => deleteSlot(i),
                        icon: Icon(
                          Icons.delete_outline,
                          color: AppColors.brownLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

// ───────────────────────── 병원용 기록 화면 ─────────────────────────

class _DayReport {
  final DateTime date;
  final Map<String, DoseRecord> doses; // 복용id → 기록
  final MoodRecord? mood;
  final bool period;
  _DayReport(this.date, this.doses, this.mood, this.period);
}

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  int range = 14; // 7 / 14 / 30일
  List<DoseSlot> slots = [];
  List<_DayReport> days = [];
  (DateTime, DateTime)? lastPeriod;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final s = await Store.loadSlots();
    final today = DateUtils.dateOnly(DateTime.now());
    final list = <_DayReport>[];
    for (int i = 0; i < range; i++) {
      final d = today.subtract(Duration(days: i));
      final doses = <String, DoseRecord>{};
      for (final slot in s) {
        final r = await Store.loadRecord(d, slot.id);
        if (r != null) doses[slot.id] = r;
      }
      list.add(
        _DayReport(
          d,
          doses,
          await MoodStore.load(d),
          await PeriodStore.isOn(d),
        ),
      );
    }
    final lp = await PeriodStore.lastPeriod();
    setState(() {
      slots = s;
      days = list;
      lastPeriod = lp;
      loading = false;
    });
  }

  String dayLabel(DateTime d) {
    final w = ['월', '화', '수', '목', '금', '토', '일'][d.weekday - 1];
    return '${d.month}/${d.day}($w)';
  }

  int get totalDoses => slots.length * days.length;
  int countStatus(RecordStatus st) =>
      days.expand((d) => d.doses.values).where((r) => r.status == st).length;
  int get moodDays => days.where((d) => d.mood != null).length;
  int moodCount(int level) => days.where((d) => d.mood?.level == level).length;

  String get percentText {
    if (totalDoses == 0) return '-';
    return '${(countStatus(RecordStatus.done) * 100 / totalDoses).round()}%';
  }

  // 예: 11/7 (10일 전) · 11/3~11/7
  String get lastPeriodText {
    if (lastPeriod == null) return '기록 없음';
    final (start, end) = lastPeriod!;
    final ago = DateUtils.dateOnly(DateTime.now()).difference(end).inDays;
    final range = start == end
        ? ''
        : ' · ${start.month}/${start.day}~${end.month}/${end.day}';
    return '${end.month}/${end.day} (${ago == 0 ? '오늘' : '$ago일 전'})$range';
  }

  // 복사용 글자로 정리
  String buildText() {
    final b = StringBuffer();
    final from = days.last.date, to = days.first.date;
    b.writeln(
      '[루틴로그 기록] ${from.month}/${from.day} ~ ${to.month}/${to.day} ($range일)',
    );
    b.writeln(
      '복용: ${countStatus(RecordStatus.done)}/$totalDoses회 ($percentText)'
      ' · 아직 ${countStatus(RecordStatus.notYet)} · 헷갈림 ${countStatus(RecordStatus.unsure)}',
    );
    b.writeln(
      '컨디션: ' +
          [
            for (int i = 0; i < moods.length; i++)
              '${moods[i].$2} ${moodCount(i)}',
          ].join(' · '),
    );
    b.writeln('마지막 생리일: $lastPeriodText');
    if (slots.isNotEmpty) {
      b.writeln(
        '복용 약: ' +
            slots
                .map(
                  (s) =>
                      '${s.name}(${s.meds.isEmpty ? '-' : s.meds.join(', ')})',
                )
                .join(' / '),
      );
    }
    b.writeln('──────────');
    for (final d in days) {
      final doseText = slots
          .map((s) {
            final r = d.doses[s.id];
            return r == null
                ? '${s.name} 미확인'
                : '${s.name} ${labelOf(r.status)} ${timeText(r.time)}';
          })
          .join(' / ');
      b.write('${dayLabel(d.date)} $doseText');
      if (d.period) b.write(' · 생리');
      if (d.mood != null) {
        b.write(' · 컨디션 ${d.mood!.label}');
        if (d.mood!.memo.isNotEmpty) b.write(' (${d.mood!.memo})');
      }
      b.writeln();
    }
    return b.toString();
  }

  Widget statBox(String title, String value) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.brown,
              ),
            ),
            SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(fontSize: 12, color: AppColors.brownLight),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.cream,
        foregroundColor: AppColors.brown,
        title: Text('병원용 기록', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: '글자로 복사',
            icon: Icon(Icons.copy_rounded, color: AppColors.brown),
            onPressed: loading
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: buildText()));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        backgroundColor: AppColors.brown,
                        content: Text('복사했어요! 카톡이나 메모에 붙여넣기 하면 돼요'),
                      ),
                    );
                  },
          ),
        ],
      ),
      body: loading
          ? SizedBox()
          : ListView(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 30),
              children: [
                // 기간 고르기
                Row(
                  children: [
                    for (final r in [7, 14, 30]) ...[
                      ChoiceChip(
                        label: Text('최근 $r일'),
                        selected: range == r,
                        selectedColor: AppColors.pinkSoft,
                        onSelected: (_) {
                          range = r;
                          load();
                        },
                      ),
                      SizedBox(width: 8),
                    ],
                  ],
                ),
                SizedBox(height: 14),

                // 요약
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.beige,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '한눈에 보기',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.brown,
                        ),
                      ),
                      SizedBox(height: 12),
                      Row(
                        children: [
                          statBox('복용률', percentText),
                          SizedBox(width: 8),
                          statBox(
                            '먹었어요',
                            '${countStatus(RecordStatus.done)}/$totalDoses',
                          ),
                          SizedBox(width: 8),
                          statBox('컨디션 기록', '$moodDays일'),
                        ],
                      ),
                      SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (int i = 0; i < moods.length; i++)
                            Column(
                              children: [
                                Image.asset(moods[i].$1, width: 34, height: 34),
                                SizedBox(height: 4),
                                Text(
                                  '${moodCount(i)}일',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.brown,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '🩸 마지막 생리일 · $lastPeriodText',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.brown,
                          ),
                        ),
                      ),
                      if (slots.isNotEmpty) ...[
                        SizedBox(height: 14),
                        Text(
                          '복용 약 · ' +
                              slots
                                  .map(
                                    (s) => s.meds.isEmpty
                                        ? s.name
                                        : '${s.name}(${s.meds.join(', ')})',
                                  )
                                  .join(' / '),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.brownLight,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(height: 16),

                // 날짜별
                for (final d in days)
                  Container(
                    margin: EdgeInsets.only(bottom: 10),
                    padding: EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.beige),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              dayLabel(d.date),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.brown,
                              ),
                            ),
                            if (d.period) ...[
                              SizedBox(width: 6),
                              Text('🩸', style: TextStyle(fontSize: 14)),
                            ],
                            Spacer(),
                            if (d.mood != null) ...[
                              Image.asset(d.mood!.image, width: 22, height: 22),
                              SizedBox(width: 4),
                              Text(
                                d.mood!.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.brownLight,
                                ),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(height: 8),
                        for (final s in slots)
                          Padding(
                            padding: EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Text(
                                  d.doses[s.id] == null
                                      ? '🌫️'
                                      : emojiOf(d.doses[s.id]!.status),
                                  style: TextStyle(fontSize: 15),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.name,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.brown,
                                    ),
                                  ),
                                ),
                                Text(
                                  d.doses[s.id] == null
                                      ? '미확인'
                                      : '${labelOf(d.doses[s.id]!.status)} · ${timeText(d.doses[s.id]!.time)}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.brownLight,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (d.mood != null && d.mood!.memo.isNotEmpty) ...[
                          SizedBox(height: 4),
                          Container(
                            width: double.infinity,
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.cream,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '📝 ${d.mood!.memo}',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.brown,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

// ───────────────────────── 달력 화면 ─────────────────────────

class CalendarScreen extends StatefulWidget {
  CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  List<DoseSlot> slots = [];
  // 날짜(일) → 복용id → 기록
  Map<int, Map<String, DoseRecord>> records = {};
  Map<int, MoodRecord> moodMap = {};
  Set<int> periodDays = {};

  @override
  void initState() {
    super.initState();
    loadMonth();
  }

  Future<void> loadMonth() async {
    final s = await Store.loadSlots();
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final result = <int, Map<String, DoseRecord>>{};
    final moodResult = <int, MoodRecord>{};
    final periodResult = <int>{};
    for (int d = 1; d <= days; d++) {
      final date = DateTime(month.year, month.month, d);
      final md = await MoodStore.load(date);
      if (md != null) moodResult[d] = md;
      if (await PeriodStore.isOn(date)) periodResult.add(d);
      for (final slot in s) {
        final rec = await Store.loadRecord(date, slot.id);
        if (rec != null) (result[d] ??= {})[slot.id] = rec;
      }
    }
    setState(() {
      slots = s;
      records = result;
      moodMap = moodResult;
      periodDays = periodResult;
    });
  }

  void changeMonth(int diff) {
    month = DateTime(month.year, month.month + diff);
    loadMonth();
  }

  int doneOn(int day) => (records[day] ?? {}).values
      .where((r) => r.status == RecordStatus.done)
      .length;

  String dayMark(int day) {
    if (slots.isEmpty || records[day] == null) return '';
    final done = doneOn(day);
    if (done == slots.length) return '💊';
    if (done > 0) return '$done/${slots.length}';
    return '·';
  }

  int get fullDays {
    if (slots.isEmpty) return 0;
    return records.keys.where((d) => doneOn(d) == slots.length).length;
  }

  void showDayInfo(DateTime date) {
    final dayRecs = records[date.day] ?? {};
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.cream,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.fromLTRB(24, 28, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${date.month}월 ${date.day}일',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.brown,
              ),
            ),
            SizedBox(height: 16),
            for (final slot in slots)
              Container(
                margin: EdgeInsets.only(bottom: 10),
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          dayRecs[slot.id] == null
                              ? '🌫️'
                              : emojiOf(dayRecs[slot.id]!.status),
                          style: TextStyle(fontSize: 22),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            slot.name,
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.brown,
                            ),
                          ),
                        ),
                        Text(
                          dayRecs[slot.id] == null
                              ? '미확인'
                              : '${labelOf(dayRecs[slot.id]!.status)} · ${timeText(dayRecs[slot.id]!.time)}',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.brownLight,
                          ),
                        ),
                      ],
                    ),
                    if (slot.meds.isNotEmpty) ...[
                      SizedBox(height: 6),
                      Padding(
                        padding: EdgeInsets.only(left: 34),
                        child: Text(
                          slot.meds.join(' · '),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.brownLight,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            SizedBox(height: 6),
            GestureDetector(
              onTap: () async {
                Navigator.pop(context);
                if (await showMoodEditor(context, date)) loadMonth();
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.beige,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    moodImage(moodMap[date.day], 28),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        (periodDays.contains(date.day) ? '🩸 생리 중\n' : '') +
                            (moodMap[date.day] == null
                                ? '컨디션 기록하기'
                                : '컨디션 · ${moodMap[date.day]!.label}'
                                      '${moodMap[date.day]!.memo.isEmpty ? '' : '\n${moodMap[date.day]!.memo}'}'),
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.brown,
                          height: 1.4,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: AppColors.brownLight,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final firstWeekday = DateTime(month.year, month.month, 1).weekday % 7;
    final totalCells = firstWeekday + days;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.cream,
        foregroundColor: AppColors.brown,
        title: Text('기록 달력', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReportScreen()),
            ),
            child: Text('🏥 병원용 기록', style: TextStyle(color: AppColors.brown)),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: 20),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: () => changeMonth(-1),
                icon: Icon(Icons.chevron_left, color: AppColors.brown),
              ),
              Text(
                '${month.year}년 ${month.month}월',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.brown,
                ),
              ),
              IconButton(
                onPressed: () => changeMonth(1),
                icon: Icon(Icons.chevron_right, color: AppColors.brown),
              ),
            ],
          ),
          SizedBox(height: 8),
          Row(
            children: ['일', '월', '화', '수', '목', '금', '토'].map((w) {
              final color = w == '일'
                  ? AppColors.pink
                  : (w == '토' ? Color(0xFF9DB4D3) : AppColors.brownLight);
              return Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: NeverScrollableScrollPhysics(),
            itemCount: totalCells,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 0.66,
            ),
            itemBuilder: (_, i) {
              if (i < firstWeekday) return SizedBox();
              final day = i - firstWeekday + 1;
              final date = DateTime(month.year, month.month, day);
              final isToday = date == today;
              final isFuture = date.isAfter(today);
              final allDone = slots.isNotEmpty && doneOn(day) == slots.length;

              return GestureDetector(
                onTap: isFuture ? null : () => showDayInfo(date),
                child: Container(
                  decoration: BoxDecoration(
                    color: allDone
                        ? AppColors.pinkSoft
                        : (isFuture
                              ? Colors.transparent
                              : AppColors.beige.withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(14),
                    border: isToday
                        ? Border.all(color: AppColors.pink, width: 2)
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 13,
                          color: isFuture
                              ? AppColors.brownLight.withOpacity(0.5)
                              : AppColors.brown,
                          fontWeight: isToday
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      SizedBox(height: 1),
                      Text(
                        dayMark(day),
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.brownLight,
                        ),
                      ),
                      if (moodMap[day] != null) moodImage(moodMap[day], 16),
                      if (periodDays.contains(day))
                        Container(
                          width: 6,
                          height: 6,
                          margin: EdgeInsets.only(top: 2),
                          decoration: BoxDecoration(
                            color: Color(0xFFF08A99),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          SizedBox(height: 24),
          Container(
            padding: EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.beige,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '이번 달 $fullDays일 다 챙겼어요 💜',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: AppColors.brown,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}
