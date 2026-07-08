import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SmartSOSApp());
}

class SmartSOSApp extends StatelessWidget {
  const SmartSOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Emergency SOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF3B30), // High contrast Red
          secondary: Color(0xFFFFD60A), // Warning Yellow
          surface: Color(0xFF1C1C1E),
        ),
        textTheme: const TextTheme(
          displayMedium: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
          bodyLarge: TextStyle(fontSize: 16, color: Color(0xFFE5E5EA)),
        ),
      ),
      home: const SOSDashboard(),
    );
  }
}

class SOSDashboard extends StatefulWidget {
  const SOSDashboard({super.key});

  @override
  State<SOSDashboard> createState() => _SOSDashboardState();
}

class _SOSDashboardState extends State<SOSDashboard> {
  // Speech to Text variables
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  String _speechWords = "Say 'HELP [FIRE/POLICE/MEDICAL]'";

  // TTS for Voice Calls
  final FlutterTts _tts = FlutterTts();

  // Bluetooth scanning (Silent Mode)
  List<BluetoothDevice> _bluetoothDevices = [];
  StreamSubscription? _btSubscription;
  bool _isBluetoothScanning = false;

  // Location & Smart Routing
  Position? _currentPosition;
  bool _isOnline = true;
  String _activeEmergency = "";
  bool _isSilentMode = false;
  Map<String, dynamic>? _nearestAgency;
  bool _isLoadingAgency = false;

  // Emergency contacts
  final List<Map<String, String>> _emergencyContacts = [
    {"name": "Emergency Contact 1", "phone": "+15550199", "relationship": "Family"},
    {"name": "Emergency Contact 2", "phone": "+15550188", "relationship": "Guardian"}
  ];

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _getCurrentLocation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkDisclaimer();
    });
  }

  Future<void> _checkDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool('disclaimer_accepted') ?? false;
    if (!accepted) {
      _showDisclaimerDialog(prefs);
    }
  }

  void _showDisclaimerDialog(SharedPreferences prefs) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(Icons.gavel, color: Color(0xFFFF3B30)),
              SizedBox(width: 8),
              Text("Legal Disclaimer", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            "This app is an emergency assistance tool and relies on third-party services like GPS, Network, and SMS gateways. "
            "The developer holds no liability for failure of alerts due to hardware, software, or signal limitations. "
            "In severe emergencies, please use official government channels (e.g., 112) immediately."
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF3B30),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                await prefs.setBool('disclaimer_accepted', true);
                Navigator.of(context).pop();
              },
              child: const Text("I Accept"),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _btSubscription?.cancel();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  // Voice analysis initialization
  void _initSpeech() async {
    bool available = await _speech.initialize(
      onStatus: (status) => print('Speech status: $status'),
      onError: (errorNotification) => print('Speech error: $errorNotification'),
    );
    if (available) {
      _startVoiceAnalysis();
    }
  }

  // Voice analysis continuous loop
  void _startVoiceAnalysis() async {
    setState(() => _isListening = true);
    await _speech.listen(
      onResult: (result) {
        setState(() {
          _speechWords = result.recognizedWords.toUpperCase();
          _analyzeVoiceCommand(_speechWords);
        });
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      cancelOnError: false,
      listenMode: stt.ListenMode.dictation,
    );
  }

  // Voice analysis trigger detection
  void _analyzeVoiceCommand(String text) {
    if (text.contains("HELP")) {
      if (text.contains("FIRE")) {
        _triggerEmergency("FIRE");
      } else if (text.contains("POLICE") || text.contains("KIDNAP")) {
        _triggerEmergency("POLICE");
      } else if (text.contains("MEDICAL") || text.contains("AMBULANCE")) {
        _triggerEmergency("MEDICAL");
      }
    }
  }

  // Get GPS Location
  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    _currentPosition = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    setState(() {});
  }

  // Trigger specific Emergency Level
  void _triggerEmergency(String type) async {
    setState(() {
      _activeEmergency = type;
      _speechWords = "EMERGENCY DETECTED: $type";
    });

    // Check device online state
    // For production, use connectivity_plus or check actual internet socket lookup.
    try {
      final response = await http.get(Uri.parse('https://clients3.google.com/generate_204')).timeout(const Duration(seconds: 3));
      _isOnline = response.statusCode == 204;
    } catch (_) {
      _isOnline = false;
    }

    if (type == "POLICE") {
      // Police or Kidnapping activates Silent Mode
      _activateSilentMode();
    } else {
      _isSilentMode = false;
    }

    if (_isOnline) {
      _performSmartRouting(type);
    } else {
      _executeOfflineFallback(type);
    }
  }

  // Perform Smart Routing (Online) - Nearest Places via Google Places API
  Future<void> _performSmartRouting(String type) async {
    if (_currentPosition == null) await _getCurrentLocation();
    if (_currentPosition == null) return;

    setState(() => _isLoadingAgency = true);

    String queryType = "hospital";
    if (type == "FIRE") queryType = "fire station";
    if (type == "POLICE") queryType = "police station";

    final lat = _currentPosition!.latitude;
    final lng = _currentPosition!.longitude;
    
    // Replace with your Google Maps API Key
    const String apiKey = "YOUR_GOOGLE_PLACES_API_KEY";
    final url = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
        '?location=$lat,$lng'
        '&radius=5000'
        '&keyword=$queryType'
        '&key=$apiKey';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List;
        if (results.isNotEmpty) {
          final first = results[0];
          setState(() {
            _nearestAgency = {
              "name": first['name'],
              "address": first['vicinity'],
              "phone": "911", // Standard emergency line fallback
              "lat": first['geometry']['location']['lat'],
              "lng": first['geometry']['location']['lng'],
            };
          });
        }
      }
    } catch (e) {
      print("Google Places API error: $e");
    } finally {
      setState(() => _isLoadingAgency = false);
    }
  }

  // Silent Mode (Black Screen, Bluetooth Scanning, Discreet logging)
  void _activateSilentMode() {
    setState(() {
      _isSilentMode = true;
    });

    _startBluetoothSniffer();
  }

  void _deactivateSilentMode() {
    setState(() {
      _isSilentMode = false;
      _isBluetoothScanning = false;
    });
    _btSubscription?.cancel();
    FlutterBluePlus.stopScan();
  }

  void _startBluetoothSniffer() async {
    if (await FlutterBluePlus.isSupported == false) return;

    setState(() => _isBluetoothScanning = true);
    _bluetoothDevices.clear();

    _btSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        if (!_bluetoothDevices.contains(r.device)) {
          setState(() {
            _bluetoothDevices.add(r.device);
          });
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  // Offline Fallback (SMS + Call TTS synthesis)
  void _executeOfflineFallback(String emergencyType) async {
    if (_currentPosition == null) await _getCurrentLocation();
    
    final lat = _currentPosition?.latitude ?? 0.0;
    final lng = _currentPosition?.longitude ?? 0.0;
    final mapsLink = "https://maps.google.com/?q=$lat,$lng";

    // 1. Send SMS to pre-saved numbers
    final String smsMessage = "ALERT! I have a $emergencyType emergency. My location is: $mapsLink";
    
    for (var contact in _emergencyContacts) {
      final phone = contact['phone']!;
      final uri = Uri.parse("sms:$phone?body=${Uri.encodeComponent(smsMessage)}");
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }

    // 2. Play TTS local alert call simulator
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.speak(
      "Warning! This is an offline emergency alert. Emergency type is $emergencyType. "
      "Latitude is ${lat.toStringAsFixed(4)} degrees, longitude is ${lng.toStringAsFixed(4)} degrees. "
      "Sending map coordinates to emergency contacts immediately."
    );
  }

  // UI rendering
  @override
  Widget build(BuildContext context) {
    if (_isSilentMode) {
      // Pure Silent Mode UI - Black screen, no light, long-press to exit
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onDoubleTap: () => _deactivateSilentMode(),
          child: Container(
            color: Colors.black,
            width: double.infinity,
            height: double.infinity,
            child: const Center(
              child: Text(
                "", // Completely black screen for stealth
                style: TextStyle(color: Colors.transparent),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("🚨 SMART SOS ACTIVE"),
        backgroundColor: const Color(0xFF1C1C1E),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(_isOnline ? Icons.wifi : Icons.wifi_off, 
              color: _isOnline ? Colors.green : Colors.red),
            onPressed: () {
              setState(() => _isOnline = !_isOnline);
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Voice Indicator
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFD60A), width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.mic, color: Color(0xFFFFD60A)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Voice Wake Word Active ('HELP')", 
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          Text(_speechWords, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    )
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Emergency Trigger Buttons (High Contrast)
              const Text("IMMEDIATE TRIGGERS", 
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildSOSButton("FIRE", const Color(0xFFFF453A), Icons.local_fire_department),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSOSButton("POLICE", const Color(0xFF0A84FF), Icons.local_police),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSOSButton("MEDICAL", const Color(0xFF30D158), Icons.medical_services),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Active Emergency Status Map / Content
              if (_activeEmergency.isNotEmpty) ...[
                Text("ACTIVE SOS: $_activeEmergency", 
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _getEmergencyColor(_activeEmergency))),
                const SizedBox(height: 10),
                if (_isOnline) ...[
                  if (_isLoadingAgency)
                    const Center(child: CircularProgressIndicator())
                  else if (_nearestAgency != null) ...[
                    // Agency Details Panel
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _getEmergencyColor(_activeEmergency)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_nearestAgency!['name'], 
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text("Address: ${_nearestAgency!['address']}", 
                            style: const TextStyle(color: Colors.grey)),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF30D158),
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () => launchUrl(Uri.parse("tel:${_nearestAgency!['phone']}")),
                                icon: const Icon(Icons.phone),
                                label: const Text("CALL STATION"),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                onPressed: () {
                                  final lat = _nearestAgency!['lat'];
                                  final lng = _nearestAgency!['lng'];
                                  launchUrl(Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lng"));
                                },
                                icon: const Icon(Icons.navigation),
                                label: const Text("GET ROUTE"),
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  ] else
                    const Text("Finding nearest emergency station within 5km...")
                ] else ...[
                  // Offline Status Indicator
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF3B30).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFF3B30)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.offline_bolt, color: Color(0xFFFF3B30)),
                            SizedBox(width: 8),
                            Text("OFFLINE FALLBACK ACTIVATED", 
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text("• GPS Lat: ${_currentPosition?.latitude ?? 'Locating...'}, Lng: ${_currentPosition?.longitude ?? 'Locating...'}",
                          style: const TextStyle(fontFamily: 'monospace')),
                        const Text("• SMS alerts drafted with automatic maps links"),
                        const Text("• Locally synthesized Text-to-Speech call starting..."),
                      ],
                    ),
                  )
                ],
                const SizedBox(height: 20),
              ],

              // Emergency Contacts List
              const Text("EMERGENCY CONTACTS", 
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 8),
              ..._emergencyContacts.map((contact) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(contact['name']!, style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text("${contact['relationship']!} • ${contact['phone']!}", 
                          styl