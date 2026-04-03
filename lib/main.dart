import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'advanced_coordinate_picker.dart';

void main() {
  runApp(const InspectorProApp());
}

/// MÓDULO 1: APLICACIÓN
class InspectorProApp extends StatelessWidget {
  const InspectorProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'INSPECTOR PRO 3',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// MÓDULO 2: CONEXIÓN NATIVA Y AJUSTES
class LocationService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');
  
  Future<String> startMocking(String latStr, String lngStr) async {
    try {
      await _channel.invokeMethod('startMocking', {
        'lat': latStr,
        'lng': lngStr,
      });
      return "SUCCESS";
    } on PlatformException catch (e) {
      return "ERROR";
    } catch (e) {
      return "ERROR";
    }
  }
  
  Future<bool> stopMocking() async {
    try {
      await _channel.invokeMethod('stopMocking');
      return true;
    } catch (e) {
      return false;
    }
  }
}

class SystemSettingsService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');
  
  Future<bool> openTimeSettings() async {
    try {
      await _channel.invokeMethod('openTimeSettings');
      return true;
    } catch (e) {
      return false;
    }
  }
}

/// MÓDULO 3: BUSCADOR AVANZADO
class GeocodingService {
  Future<LatLng?> searchAddress(String query) async {
    if (query.isEmpty) return null;
    
    final String cleanQuery = query.toLowerCase().replaceAll(RegExp(r'\b(sa|s\.a\.|sl|s\.l\.)\b'), '').trim();
    final Uri nominatimUrl = Uri.parse('https://nominatim.openstreetmap.org/search?q=$cleanQuery&format=json&limit=1');
    
    try {
      final response = await http.get(nominatimUrl, headers: {'User-Agent': 'InspectorPro3'});
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          final double lat = double.parse(data[0]['lat'].toString());
          final double lon = double.parse(data[0]['lon'].toString());
          return LatLng(lat, lon);
        }
      }
    } catch (e) {
      debugPrint("Fallo Nominatim: $e");
    }

    final Uri photonUrl = Uri.parse('https://photon.komoot.io/api/?q=$cleanQuery&limit=1');
    try {
      final response = await http.get(photonUrl);
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<dynamic> features = data['features'];
        if (features.isNotEmpty) {
          final coords = features[0]['geometry']['coordinates'];
          final double lat = double.parse(coords[1].toString());
          final double lon = double.parse(coords[0].toString());
          return LatLng(lat, lon);
        }
      }
    } catch (e) {
      debugPrint("Error búsqueda Photon: $e");
    }
    return null;
  }
}

/// MÓDULO 4: PANTALLA PRINCIPAL
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  final GeocodingService _geocodingService = GeocodingService();
  final SystemSettingsService _systemSettingsService = SystemSettingsService();
  
  LatLng _center = const LatLng(36.7213, -4.4214); // Málaga Centro
  bool _isMocking = false;
  bool _isSatellite = false; 
  bool _isLoadingSearch = false;
  
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _photos = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadAndCleanPhotos();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [Permission.locationWhenInUse, Permission.locationAlways].request();
  }

  // --- GESTIÓN Y BORRADO FÍSICO DE FOTOS ---
  Future<void> _loadAndCleanPhotos() async {
    final prefs = await SharedPreferences.getInstance();
    final String? photosJson = prefs.getString('saved_photos');
    
    if (photosJson != null) {
      List<dynamic> decoded = json.decode(photosJson);
      List<Map<String, dynamic>> loadedPhotos = decoded.cast<Map<String, dynamic>>();
      
      // AUTO-DESTRUCCIÓN FÍSICA: Elimina el archivo JPG y el registro si tiene > 7 días
      loadedPhotos.removeWhere((f) {
        try {
          final date = DateTime.parse(f['timestamp']);
          if (DateTime.now().difference(date).inDays > 7) {
            if (f.containsKey('photo_path') && f['photo_path'] != null) {
              final file = File(f['photo_path']);
              if (file.existsSync()) {
                file.deleteSync(); // Borrado físico del disco
              }
            }
            return true; // Lo borra de la lista visual
          }
          return false;
        } catch (e) {
          return false;
        }
      });

      setState(() {
        _photos = loadedPhotos;
        _photos.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
      });
      
      _savePhotosToDisk(); 
    }
  }

  Future<void> _savePhotosToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_photos', json.encode(_photos));
  }

  Future<void> _takePhotoCheckpoint() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera);
    
    if (image == null) return;
    
    setState(() {
      _photos.add({
        'lat': _center.latitude,
        'lng': _center.longitude,
        'timestamp': DateTime.now().toIso8601String(),
        'photo_path': image.path,
      });
      _photos.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    });
    
    _savePhotosToDisk();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto Checkpoint Guardada.'), backgroundColor: Colors.green)
      );
    }
  }

  void _showPhotoGallery() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        if (_photos.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24.0), 
            child: Text('No hay fotos recientes.', style: TextStyle(fontSize: 16), textAlign: TextAlign.center)
          );
        }
        
        return ListView.builder(
          itemCount: _photos.length,
          itemBuilder: (context, index) {
            final f = _photos[index];
            final DateTime date = DateTime.parse(f['timestamp']);
            final String timeString = "${date.day}/${date.month}/${date.year} a las ${date.hour}:${date.minute.toString().padLeft(2, '0')}";
            
            final int daysOld = DateTime.now().difference(date).inDays;
            final int daysLeft = 7 - daysOld;
            
            Widget leadingIcon = const Icon(Icons.broken_image, color: Colors.grey);
            if (f.containsKey('photo_path') && f['photo_path'] != null) {
              final file = File(f['photo_path']);
              if (file.existsSync()) {
                leadingIcon = ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(file, width: 50, height: 50, fit: BoxFit.cover),
                );
              }
            }
            
            return ListTile(
              leading: leadingIcon,
              title: Text(timeString, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Lat: ${f['lat'].toStringAsFixed(5)}, Lng: ${f['lng'].toStringAsFixed(5)}\nQuedan $daysLeft días'),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () {
                  // Borrado manual (borra de la lista y del disco duro)
                  if (f.containsKey('photo_path') && f['photo_path'] != null) {
                    final file = File(f['photo_path']);
                    if (file.existsSync()) {
                      file.deleteSync();
                    }
                  }
                  setState(() {
                    _photos.removeAt(index);
                    _savePhotosToDisk();
                  });
                  Navigator.pop(context);
                  _showPhotoGallery();
                },
              ),
              onTap: () {
                Navigator.pop(context);
                final newPos = LatLng(f['lat'], f['lng']);
                _mapController.move(newPos, 16.0);
                setState(() => _center = newPos);
              },
            );
          },
        );
      }
    );
  }

  // --- CONTROL DE MAPA E INYECCIÓN ---
  Future<void> _searchAddress() async {
    final query = _searchController.text;
    if (query.isEmpty) return;

    setState(() => _isLoadingSearch = true);
    FocusScope.of(context).unfocus();

    final LatLng? result = await _geocodingService.searchAddress(query);
    
    setState(() => _isLoadingSearch = false);

    if (result != null) {
      _mapController.move(result, 16.0);
      setState(() => _center = result);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se encontró la dirección.')));
      }
    }
  }

  Future<void> _toggleMock() async {
    if (_isMocking) {
      await _locationService.stopMocking();
      setState(() => _isMocking = false);
    } else {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        await _requestPermissions();
        return;
      }
      
      // EL BLINDAJE ABSOLUTO: Mandamos Texto cortado a 7
      final String finalLatStr = _center.latitude.toStringAsFixed(7);
      final String finalLngStr = _center.longitude.toStringAsFixed(7);

      final String result = await _locationService.startMocking(finalLatStr, finalLngStr);
      
      if (result == "SUCCESS") {
        setState(() => _isMocking = true);
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de permisos en Opciones de Desarrollador.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('INSPECTOR PRO 3', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.access_time),
            tooltip: 'Ajustar Fecha y Hora',
            onPressed: () {
              _systemSettingsService.openTimeSettings();
            },
          ),
          IconButton(
            icon: const Icon(Icons.photo_library),
            tooltip: 'Ver Fotos Guardadas',
            onPressed: _showPhotoGallery,
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 16.0,
              onPositionChanged: (pos, hasGesture) {
                if (pos.center != null && !_isMocking) {
                  setState(() => _center = pos.center!);
                }
              },
              interactionOptions: InteractionOptions(
                flags: _isMocking ? InteractiveFlag.none : InteractiveFlag.all
              )
            ),
            children: [
              TileLayer(
                // LA MEJORA BRUTAL: Alternador con Satélite Oficial de Google Maps
                urlTemplate: _isSatellite 
                  ? 'https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.v4.inspector',
              ),
            ],
          ),
          
          Center(
            child: Icon(
              _isMocking ? Icons.gps_fixed : Icons.location_searching, 
              color: _isMocking ? Colors.green : Colors.red, 
              size: 40
            ),
          ),
          
          Positioned(
            top: 20,
            left: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(hintText: 'Buscar dirección...', border: InputBorder.none),
                      onSubmitted: (_) => _searchAddress(),
                    ),
                  ),
                  _isLoadingSearch 
                    ? const Padding(padding: EdgeInsets.all(12.0), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(icon: const Icon(Icons.search), onPressed: _searchAddress),
                ],
              ),
            ),
          ),

          Positioned(
            right: 15,
            bottom: 20,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'satBtn',
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.blueGrey[900],
                  onPressed: () {
                    setState(() {
                      _isSatellite = !_isSatellite;
                    });
                  },
                  child: Icon(_isSatellite ? Icons.map : Icons.satellite_alt),
                ),
                const SizedBox(height: 10),
                FloatingActionButton(
                  heroTag: 'camBtn',
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  onPressed: _takePhotoCheckpoint,
                  child: const Icon(Icons.camera_alt),
                ),
              ],
            ),
          )
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(20),
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Lat: ${_center.latitude.toStringAsFixed(7)}",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              "Lng: ${_center.longitude.toStringAsFixed(7)}",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 15),
            SrunElevatedButton(
              onPressed: _toggleMock,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isMocking ? Colors.red : Colors.green[700],
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
              ),
              child: Text(
                _isMocking ? "DETENER" : "INICIAR INSPECTOR PRO 3",
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SrunElevatedButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Widget child;
  final ButtonStyle style;

  const SrunElevatedButton({
    super.key,
    required this.onPressed,
    required this.child,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: style,
      child: child,
    );
  }
}
