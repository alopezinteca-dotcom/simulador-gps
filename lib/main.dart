import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:io';

import 'services/location_channel.dart';
import 'services/mock_service.dart';
import 'services/geocoding_service.dart';
import 'services/photo_service.dart';
import 'services/validation_service.dart';
import 'services/settings_service.dart';

import 'widgets/top_menu.dart';
import 'widgets/mock_controls.dart';
import 'widgets/photo_gallery.dart';
import 'widgets/coordinate_dialog.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const InspectorProApp());
}

class InspectorProApp extends StatelessWidget {
  const InspectorProApp({super.key});

  @override
  Widget build(context) {
    return MaterialApp(
      title: "Inspector Pro 3",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF263238),
          primary: const Color(0xFF1976D2),
        ),
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _map = MapController();

  final LocationChannel _channel = LocationChannel();
  final MockService _mock = MockService();
  final GeocodingService _geo = GeocodingService();
  final SettingsService _settings = SettingsService();

  LatLng _center = const LatLng(36.7213, -4.4214);

  bool _mocking = false;
  bool _sat = false;

  bool _chkSpeed = true;
  bool _chkBounds = false;

  LatLng? _last;
  DateTime? _lastTime;

  List<Map<String, dynamic>> _photos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPhotos();
    _reqPerms();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkShared());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState st) {
    if (st == AppLifecycleState.resumed) {
      _checkShared();
    }
  }

  Future<void> _reqPerms() async {
    await [
      Permission.locationWhenInUse,
      Permission.locationAlways,
      Permission.notification,
    ].request();
  }

  Future<void> _checkShared() async {
    final txt = await _channel.getSharedText();
    if (txt == null || txt.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Procesando enlace...")),
    );

    final pos = await _geo.resolve(txt);
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No se pudo extraer la coordenada."),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _center = LatLng(pos.latitude, pos.longitude);
      _map.move(_center, 17);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Ubicación capturada."),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _loadPhotos() async {
    _photos = await PhotoService.cleanAndLoad();
    setState(() {});
  }

  Future<void> _pickPhoto() async {
    final data = await PhotoService.takeForensicPhoto(_center);
    if (data == null) return;

    _photos.add(data);
    _photos.sort((a, b) =>
        (b['timestamp'] as String).compareTo(a['timestamp'] as String));

    await PhotoService.save(_photos);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Foto guardada."),
        backgroundColor: Colors.green,
      ),
    );

    setState(() {});
  }

  void _openGallery() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => PhotoGallery(
        photos: _photos,
        onJump: (p) {
          Navigator.pop(context);
          Future.delayed(const Duration(milliseconds: 300), () {
            setState(() {
              _center = p;
              _map.move(p, 17);
            });
          });
        },
        onDelete: (i) async {
          final path = _photos[i]['photo_path'];
          if (path != null && File(path).existsSync()) {
            File(path).deleteSync();
          }
          setState(() {
            _photos.removeAt(i);
          });
          await PhotoService.save(_photos);

          Navigator.pop(context);
          _openGallery();
        },
      ),
    );
  }

  // ✅ NULL-SAFETY 100% CORREGIDO
  Future<void> _goReal() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Activa el GPS físico.")),
      );
      return;
    }

    var p = await Geolocator.getLastKnownPosition();
    if (p != null) {
      setState(() {
        _center = LatLng(p.latitude, p.longitude);
        _map.move(_center, 17);
      });
    }

    try {
      p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 8),
      );

      if (p != null) {
        setState(() {
          _center = LatLng(p.latitude, p.longitude);
          _map.move(_center, 17);
        });
      }
    } catch (_) {}
  }

  void _adjust(double dLat, double dLng) {
    if (_mocking) return;

    setState(() {
      _center = LatLng(
        _center.latitude + dLat,
        _center.longitude + dLng,
      );
      _map.move(_center, _map.camera.zoom);
    });
  }

  Future<void> _toggleMock() async {
    if (_mocking) {
      await _mock.stop();
      setState(() => _mocking = false);
      return;
    }

    if (_chkBounds) {
      final warn = ValidationService.spain(_center);
      if (warn != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(warn), backgroundColor: Colors.orange),
        );
      }
    }

    if (_chkSpeed && _last != null && _lastTime != null) {
      final warn = ValidationService.jump(_last!, _lastTime!, _center);
      if (warn != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(warn), backgroundColor: Colors.orange),
        );
      }
    }

    final res = await _mock.start(_center);
    if (res != "SUCCESS") {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Selecciona esta app en 'Opciones de Desarrollador'"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _mocking = true;
      _last = _center;
      _lastTime = DateTime.now();
    });
  }

  @override
  Widget build(context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 17,
              onPositionChanged: (pos, gesture) {
                if (!_mocking && pos.center != null && gesture) {
                  setState(() => _center = pos.center!);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _sat
                    ? "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}"
                    : "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName: "com.inspector.pro",
              ),
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: _center,
                    radius: 15,
                    useRadiusInMeter: true,
                    color: Colors.yellowAccent.withOpacity(0.2),
                    borderColor: Colors.yellow,
                  ),
                  CircleMarker(
                    point: _center,
                    radius: 5,
                    useRadiusInMeter: true,
                    color: Colors.green.withOpacity(0.3),
                    borderColor: Colors.green,
                  ),
                ],
              ),
            ],
          ),

          Center(
            child: Icon(
              _mocking ? Icons.gps_fixed : Icons.add_circle_outline,
              color: _mocking ? Colors.green : Colors.red,
              size: 44,
            ),
          ),

          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: TopMenu(
                onRealLocation: _goReal,
                onToggleSat: () => setState(() => _sat = !_sat),
                isSatellite: _sat,
                onPhoto: _pickPhoto,
                onGallery: _openGallery,
                onSettings: () => showModalBottomSheet(
                  context: context,
                  builder: (_) => _buildSettingsSheet(),
                ),
              ),
            ),
          ),

          MockControls(
            center: _center,
            isMocking: _mocking,
            onAdjust: _adjust,
          ),

          SafeArea(
            child: _buildBottomPanel(),
          )
        ],
      ),
    );
  }

  Widget _buildSettingsSheet() {
    return StatefulBuilder(
      builder: (_, setModal) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "⚙️ Ajustes de Auditoría",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Divider(),

              SwitchListTile(
                title: const Text("Alerta de velocidad (>120km/h)"),
                value: _chkSpeed,
                onChanged: (v) {
                  setModal(() => _chkSpeed = v);
                  setState(() => _chkSpeed = v);
                },
              ),

              SwitchListTile(
                title: const Text("Límite geográfico (España)"),
                value: _chkBounds,
                onChanged: (v) {
                  setModal(() => _chkBounds = v);
                  setState(() => _chkBounds = v);
                },
              ),

              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text("Ajustar hora del sistema"),
                onTap: () {
                  Navigator.pop(context);
                  _settings.openTimeSettings();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomPanel() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 10,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "OBJETIVO (WGS84 - 7 Dec)",
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "Lat: ${_center.latitude.toStringAsFixed(7)}",
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "Lng: ${_center.longitude.toStringAsFixed(7)}",
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),

                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey[100],
                    ),
                    icon: const Icon(Icons.edit_location_alt),
                    label: const Text("PLANTILLA"),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) {
                          return DefaultTabController(
                            length: 4,
                            child: CoordinateDialog(
                              onResult: (p) {
                                setState(() {
                                  _center = p;
                                  _map.move(p, 17);
                                });
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),

              const SizedBox(height: 16),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _mocking ? Colors.red[700] : Colors.green[700],
                  minimumSize: const Size(double.infinity, 60),
                ),
                onPressed: _toggleMock,
                child: Text(
                  _mocking
                      ? "🛑 DETENER SIMULACIÓN"
                      : "🚀 INICIAR SIMULACIÓN BLINDADA",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
