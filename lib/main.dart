import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:map_box_geocoder/map_box_geocoder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:geocoding/geocoding.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WakelockPlus.enable();
  runApp(const OneMinuteNaviApp());
}

class OneMinuteNaviApp extends StatelessWidget {
  const OneMinuteNaviApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NoWay',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.grey,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const NaviScreen(),
    );
  }
}

class NaviScreen extends StatefulWidget {
  const NaviScreen({Key? key}) : super(key: key);

  @override
  State<NaviScreen> createState() => _NaviScreenState();
}

const int cycleSeconds = 10;
const double arrivalDistance = 20.0;

class _NaviScreenState extends State<NaviScreen> {
  bool _isNavigating = false;
  bool _hasArrived = false;
  int _currentCycleSeconds = cycleSeconds;
  final ValueNotifier<int> _remainingSeconds = ValueNotifier<int>(cycleSeconds);
  Timer? _countdownTimer;

  // 目的地情報
  double? _destLat;
  double? _destLng;
  String _destName = "";
  
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  final mapbox_client = MapBoxClient('TOKEN');

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // --- ⭕️追加: 現在地を取得するヘルパーメソッド ---
  Future<Position?> _getCurrentPositionForSearch() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;
    
    try {
      return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    } catch (e) {
      return null;
    }
  }

  // --- ⭕️追加: 目的地をセットして通知する共通メソッド ---
  void _setDestination(String name, double lat, double lng) {
    setState(() {
      _destLat = lat;
      _destLng = lng;
      _destName = name;
    });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(showCloseIcon: true, content: Text('目的地を「$_destName」に設定しました')),
      );
    }
  }

  // --- ⭕️追加: 複数の候補を「距離」でリスト表示するボトムシート ---
  void _showDistanceSelectionSheet(String query, List<Location> locations, Position currentPos) {
    // 1. 各候補の距離を計算
    List<Map<String, dynamic>> destList = locations.map((loc) {
      double dist = Geolocator.distanceBetween(
        currentPos.latitude, currentPos.longitude,
        loc.latitude, loc.longitude,
      );
      return {'location': loc, 'distance': dist};
    }).toList();

    // 2. 距離が近い順に並び替え
    destList.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '「$query」が複数見つかりました',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: destList.length,
                  itemBuilder: (context, index) {
                    final item = destList[index];
                    final loc = item['location'] as Location;
                    final dist = item['distance'] as double;
                    
                    // 距離を見やすくフォーマット
                    String distStr;
                    if (dist >= 1000) {
                      distStr = '${(dist / 1000).toStringAsFixed(1)} km';
                    } else {
                      distStr = '${dist.toStringAsFixed(0)} m';
                    }

                    return ListTile(
                      leading: const Icon(Icons.place, color: Colors.white70),
                      title: Text(
                        'ここから $distStr',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white30, size: 16),
                      onTap: () {
                        Navigator.pop(context); // シートを閉じる
                        _setDestination(query, loc.latitude, loc.longitude);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _searchDestination() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _destLat = null;
      _destLng = null;
      _destName = "";
      _isSearching = true;
    });

    // geocodingパッケージは結果がない場合エラーをスローすることがあるため try-catch で囲む
    final result = await mapbox_client.geocoding.forwardSearch(query);
    List<Location> locations = result.features.map((feature) => feature.bbox).map((bbox) => Location(latitude: (bbox![0] + bbox[1])/2, longitude: (bbox[2] + bbox[3])/2)).toList();
    
    if (locations.isNotEmpty) {
      if (locations.length == 1) {
        // 候補が1つだけならそのまま設定
        _setDestination(query, locations.first.latitude, locations.first.longitude);
      } else {
        // 候補が複数の場合、現在地を取得して距離を計算する
        Position? currentPos = await _getCurrentPositionForSearch();
        
        if (currentPos != null) {
          _showDistanceSelectionSheet(query, locations, currentPos);
        } else {
          // 位置情報が拒否されている等で取得できない場合は、一番最初の候補を設定
          _setDestination(query, locations.first.latitude, locations.first.longitude);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(showCloseIcon: true, content: Text('現在地が取得できないため、最初の候補を設定しました')),
            );
          }
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(showCloseIcon: true, content: Text('場所が見つかりませんでした。別のキーワードでお試しください。')),
        );
      }
    }

    setState(() {
      _isSearching = false;
    });
  }

  // --- ナビゲーションの開始と停止 ---
  void _toggleNavigation() async {
    if (_isNavigating) {
      _stopNavigation();
    } else {
      if (_destLat == null || _destLng == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(showCloseIcon: true, content: Text('先に目的地を検索・設定してください')),
        );
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      
      // 画面消灯時もGPSを取得しやすくするため「常に許可(Always)」をリクエスト
      if (permission == LocationPermission.whileInUse) {
        // ※ OSの設定画面に飛ばす等の処理が本来は推奨されますが、ここではリクエストのみ行います
        await Geolocator.requestPermission();
      }

      _startNavigation();
    }
  }

  void _startNavigation() {
    setState(() {
      _isNavigating = true;
      _hasArrived = false;
    });
    _currentCycleSeconds = cycleSeconds;
    _remainingSeconds.value = cycleSeconds;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _remainingSeconds.value--;

      if (_remainingSeconds.value <= 0) {
        _checkDirectionAndVibrate();
        _remainingSeconds.value = _currentCycleSeconds;
      }
    });
  }

  void _stopNavigation({bool isArrival = false}) {
    _countdownTimer?.cancel();
    setState(() {
      _isNavigating = false;
      _hasArrived = isArrival;
    });
    _currentCycleSeconds = cycleSeconds;
    _remainingSeconds.value = cycleSeconds;
  }

  // --- 方向判定・到着判定と振動ロジック ---
  Future<void> _checkDirectionAndVibrate() async {
    if (_destLat == null || _destLng == null) return;

    try {
      // 現在地を取得
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 到着判定（現在地と目的地の距離を計算）
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        _destLat!,
        _destLng!,
      );

      bool hasVibrator = await Vibration.hasVibrator() ?? false;

      if (distance <= arrivalDistance) {
        _stopNavigation(isArrival: true);
        if (hasVibrator) {
          // 長めのバイブレーション（ブー、ブー、ブー、ブーーーーン）
          Vibration.vibrate(
            pattern: [0, 500, 200, 500, 200, 500, 200, 2000],
            intensities: [0, 255, 0, 255, 0, 255, 0, 255],
          );
        }
        return; // 到着したら方向判定はスキップ
      }

      if (distance <= 30) {
        _currentCycleSeconds = 3;
      } else if (distance <= 70) {
        _currentCycleSeconds = 5;
      } else {
        _currentCycleSeconds = 10;
      }

      // --- 以降は通常の方向判定 ---
      final double currentHeading = position.heading;
      final double bearingToDest = Geolocator.bearingBetween(
        position.latitude,
        position.longitude,
        _destLat!,
        _destLng!,
      );

      double relativeAngle = (bearingToDest - currentHeading) % 360;
      if (relativeAngle < 0) relativeAngle += 360;

      if (!hasVibrator) return;

      if (relativeAngle >= 10 && relativeAngle <= 170) {
        // 右
        Vibration.vibrate(pattern: [0, 200, 200, 200], intensities: [0, 255, 0, 255]);
      } else if (relativeAngle >= 190 && relativeAngle <= 350) {
        // 左
        Vibration.vibrate(duration: 1000, amplitude: 255);
      } else {
        // 正面または背面
        Vibration.vibrate(pattern: [0, 100, 100, 100, 100, 100], intensities: [0, 255, 0, 255, 0, 255]);
      }
    } catch (e) {
      debugPrint("エラー: $e");
    }
  }

  Widget _buildVibrationGuideRow(IconData icon, String direction, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 28),
          const SizedBox(width: 16),
          SizedBox(
            width: 60,
            child: Text(
              direction,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
            ),
          ),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _checkFirstLaunch();
  }

  Future<void> _checkFirstLaunch() async {
    // データを保存する領域にアクセス
    final prefs = await SharedPreferences.getInstance();
    
    final isFirstLaunch = prefs.getBool('isFirstLaunch') ?? true;

    if (isFirstLaunch) {
      await prefs.setBool('isFirstLaunch', false);
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDialog(
          context: context,
          builder: (context) => const TutorialDialog(),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          DiagonalIconBackground(isNavigating: _isNavigating),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 到着時の画面UI
                  if (_hasArrived) ...[
                    const Spacer(),
                    const Icon(Icons.location_on, size: 80, color: Colors.orangeAccent),
                    const SizedBox(height: 16),
                    const Text(
                        '到着',
                        style: TextStyle(
                          fontSize: 60,
                          fontWeight: FontWeight.bold,
                          color: Colors.orangeAccent,
                          letterSpacing: 4.0,
                        ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text('お疲れさまでした！\n目的地: $_destName', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Colors.white70))
                    ),
                    const Spacer(),
                  ] 
                  // ホーム画面 (ナビ開始前)
                  else if (!_isNavigating) ...[
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        icon: const Icon(Icons.help_outline, color: Colors.white54, size: 28),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const TutorialDialog(),
                          );
                        },
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'NoWay',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 4.0),
                    ),
                    const Spacer(),
                    TextField(
                      onChanged: (text) {
                        setState(() {});
                      },
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '目的地を入力 (例: 東京駅)',
                        filled: true,
                        fillColor: Colors.grey[900],
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: _isSearching
                            ? const RepaintBoundary(
                                  child: Padding(
                                    padding: EdgeInsets.all(12.0),
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                )
                              : IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: _searchDestination,
                              )
                      ),
                      onSubmitted: (_) => _searchDestination(),
                    ),
                    const SizedBox(height: 16),
                    if (_destName.isNotEmpty)
                      Text(
                        '目的地: $_destName',
                        style: const TextStyle(fontSize: 16, color: Colors.greenAccent),
                      ),
                    const Spacer(),
                  ] 
                  // ナビゲーション中 (タイマー画面)
                  else ...[
                    const Spacer(),
                    ValueListenableBuilder<int>(
                      valueListenable: _remainingSeconds,
                      builder: (context, seconds, child) {
                        return Text(
                          "00:${seconds.toString().padLeft(2, '0')}", // ← ここでテキストを作る
                          style: const TextStyle(
                            fontSize: 80,
                            fontWeight: FontWeight.w200,
                            letterSpacing: 4.0,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 40),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            '振動パターンの意味',
                            style: TextStyle(color: Colors.grey, fontSize: 14, letterSpacing: 1.2),
                          ),
                          const Text(
                            '（停止時は正確ではありません。）',
                            style: TextStyle(color: Colors.grey, fontSize: 14, letterSpacing: 1.2),
                          ),
                          const SizedBox(height: 16),
                          _buildVibrationGuideRow(Icons.turn_right, '右', 'トン・トン（2回連続）'),
                          _buildVibrationGuideRow(Icons.turn_left, '左', 'ブーーーン（長く1回）'),
                        ],
                      ),
                    ),
                    const Spacer(),
                  ],

                  // START / STOP / HOMEへ戻る ボタン
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        if (_hasArrived) {
                          // 到着画面からはホームへ戻る
                          setState(() => _hasArrived = false);
                        } else {
                          _toggleNavigation();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        foregroundColor: _isNavigating ? Colors.redAccent : Colors.black,
                        backgroundColor: _isNavigating ? Colors.transparent : Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                          side: BorderSide(
                            color: _isNavigating ? Colors.redAccent : Colors.white,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 20),
                      ),
                      child: Text(
                        _hasArrived ? 'ホームへ戻る' : (_isNavigating ? 'STOP' : 'START'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
      ]),
    );
  }

  void _clearDestination() {
    setState(() {
      _destLat = null;
      _destLng = null;
      _destName = "";
    });
  }
}

class DiagonalIconBackground extends StatefulWidget {
  final bool isNavigating;
  const DiagonalIconBackground({Key? key, required this.isNavigating}) : super(key: key);

  @override
  State<DiagonalIconBackground> createState() => _DiagonalIconBackgroundState();
}

class _DiagonalIconBackgroundState extends State<DiagonalIconBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 12));
    if (widget.isNavigating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(DiagonalIconBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isNavigating != oldWidget.isNavigating) {
      if (widget.isNavigating) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final itemSize = MediaQuery.of(context).size.width / 8;
    final loopDistance = itemSize * 2;

    return IgnorePointer(
      child: RepaintBoundary(
        child: Transform.scale(
          scale: 2.5,
          child: Transform.rotate(
            angle: -0.4,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, -(_controller.value * loopDistance)),
                  child: child,
                );
              },
              child: Wrap(
                children: List.generate(200, (index) {
                  final isRight = (index % 2) == 0;
                  return SizedBox(
                    width: itemSize,
                    height: itemSize,
                    child: Icon(
                      isRight ? Icons.turn_right : Icons.turn_left,
                      color: Colors.white.withOpacity(0.05),
                      size: 32,
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TutorialDialog extends StatefulWidget {
  const TutorialDialog({Key? key}) : super(key: key);

  @override
  State<TutorialDialog> createState() => _TutorialDialogState();
}

class _TutorialDialogState extends State<TutorialDialog> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  void _testVibration(String direction) async {
    bool hasVibrator = await Vibration.hasVibrator() ?? false;
    if (!hasVibrator) return;

    if (direction == 'right') {
      Vibration.vibrate(pattern: [0, 200, 200, 200], intensities: [0, 255, 0, 255]);
    } else if (direction == 'left') {
      Vibration.vibrate(duration: 1000, amplitude: 255);
    } else if (direction == 'straight') {
      Vibration.vibrate(pattern: [0, 100, 100, 100, 100, 100], intensities: [0, 255, 0, 255, 0, 255]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        height: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) => setState(() => _currentPage = index),
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.directions_walk, size: 80, color: Colors.white70),
                      SizedBox(height: 24),
                      Text('画面を見ないナビ', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      SizedBox(height: 16),
                      Text('NoWayは、画面の地図を見ずに\n「振動」だけで目的地へ導きます。\n歩きスマホはもう不要です。', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, height: 1.5)),
                    ],
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.search, size: 80, color: Colors.white70),
                      SizedBox(height: 24),
                      Text('使い方は簡単', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      SizedBox(height: 16),
                      Text('目的地を検索してSTARTを押し、\nスマホをポケットに入れるだけ。\n10秒に1回、進む方向を振動で教えます。', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, height: 1.5)),
                    ],
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.vibration, size: 64, color: Colors.greenAccent),
                      const SizedBox(height: 16),
                      const Text('振動をテストしてみよう', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _testVibration('left'),
                            icon: const Icon(Icons.turn_left, size: 18),
                            label: const Text('左'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                          ),
                          ElevatedButton.icon(
                            onPressed: () => _testVibration('right'),
                            icon: const Icon(Icons.turn_right, size: 18),
                            label: const Text('右'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: List.generate(3, (index) => Container(
                    margin: const EdgeInsets.only(right: 8),
                    width: _currentPage == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentPage == index ? Colors.white : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  )),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('閉じる', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}