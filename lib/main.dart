import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:utm/utm.dart';
import 'dart:convert';
import 'advanced_coordinate_picker.dart';

void main() {
  runApp(const MockLocationApp());
}

/// MÓDULO 1: Aplicación Principal
class MockLocationApp extends StatelessWidget {
  const MockLocationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Simulador GPS Pro',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// MÓDULO 2: Servicio de Comunicación Nativa (GPS)
class LocationService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');

  Future<bool> startMocking(double lat, double lng) async {
    try {
      await _channel.invokeMethod('startMocking', {'lat': lat, 'lng': lng});
      return true;
    } catch (e) {
      debugPrint("Error al iniciar Mock Location: $e");
      return false;
    }
  }

  Future<bool> stopMocking() async {
    try {
      await _channel.invokeMethod('stopMocking');
      return true;
    } catch (e) {
      debugPrint("Error al detener Mock Location: $e");
      return false;
    }
  }
}

/// MÓDULO 3: Servicio de Geocodificación (Buscador)
class GeocodingService {
  Future<LatLng?> searchAddress(String query) async {
    if (query.isEmpty) {
      return null;
    }
    
    final Uri url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=1');
    
    try {
      final response = await http.get(
        url, 
        headers: {
          'User-Agent': 'MockGpsApp/1.4',
        }
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          final double lat = double.parse(data[0]['lat'].toString());
          final double lon = double.parse(data[0]['lon'].toString());
          return LatLng(lat, lon);
        }
      }
    } catch (e) {
      debugPrint("Error en la búsqueda de dirección: $e");
    }
    return null;
  }
}

/// MÓDULO 4: Formateador y Conversor de Coordenadas
class CoordinateFormatter {
  static double enforce7Decimals(double value) {
    return double.parse(value.toStringAsFixed(7));
  }
}

/// MÓDULO 5: Servicio de Ajustes del Sistema
class SystemSettingsService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');

  Future<bool> openTimeSettings() async {
    try {
      await _channel.invokeMethod('openTimeSettings');
      return true;
    } catch (e) {
      debugPrint("Error al abrir ajustes de hora: $e");
      return false;
    }
  }
}

/// MÓDULO 6: Pantalla Principal y Mapa
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() {
    return _MapScreenState();
  }
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  final GeocodingService _geocodingService = GeocodingService();
  final SystemSettingsService _systemSettingsService = SystemSettingsService();
  final TextEditingController _searchController = TextEditingController();

  LatLng _selectedPosition = const LatLng(36.7213, -4.4214);
  bool _isMocking = false;
  bool _isLoadingSearch = false;

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    setState(() {
      _selectedPosition = position;
    });
  }

  Future<void> _performSearch() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isLoadingSearch = true;
    });

    final LatLng? result = await _geocodingService.searchAddress(query);

    setState(() {
      _isLoadingSearch = false;
    });

    if (result != null) {
      setState(() {
        _selectedPosition = result;
      });
      _mapController.move(result, 15.0);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se encontró la dirección.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _toggleMockLocation() async {
    if (_isMocking) {
      final bool success = await _locationService.stopMocking();
      if (success) {
        setState(() {
          _isMocking = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Simulación de GPS detenida.'),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } else {
      final double lat7 = CoordinateFormatter.enforce7Decimals(_selectedPosition.latitude);
      final double lng7 = CoordinateFormatter.enforce7Decimals(_selectedPosition.longitude);

      final bool success = await _locationService.startMocking(lat7, lng7);
      if (success) {
        setState(() {
          _isMocking = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Simulando ubicación con éxito.'),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error. ¿Activaste la app en Opciones de Desarrollador?'),
              duration: Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isMocking ? 'Simulando GPS...' : 'Simulador GPS Pro'),
        backgroundColor: _isMocking ? Colors.green[600] : Colors.blueAccent,
        foregroundColor: Colors.white,
        elevation: 4.0,
        actions: [
          IconButton(
            icon: const Icon(Icons.access_time),
            tooltip: 'Cambiar Hora del Sistema',
            onPressed: () async {
              await _systemSettingsService.openTimeSettings();
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit_location_alt),
            tooltip: 'Convertidor / Editor Avanzado',
            onPressed: () async {
              final LatLng? newPos = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AdvancedCoordinatePicker(
                    initialPosition: _selectedPosition,
                  ),
                ),
              );
              if (newPos != null) {
                setState(() {
                  _selectedPosition = newPos;
                });
                _mapController.move(newPos, 15.0);
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _selectedPosition,
              initialZoom: 14.0,
              onTap: _onMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mockgps',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _selectedPosition,
                    width: 60.0,
                    height: 60.0,
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.redAccent,
                      size: 50.0,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            bottom: 24.0,
            left: 16.0,
            right: 180.0,
            child: Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(15.0),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8.0,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Ubicación seleccionada:',
                    style: TextStyle(fontSize: 12.0, color: Colors.grey, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4.0),
                  Text(
                    'Lat: ${CoordinateFormatter.enforce7Decimals(_selectedPosition.latitude)}',
                    style: const TextStyle(fontSize: 14.0, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    'Lng: ${CoordinateFormatter.enforce7Decimals(_selectedPosition.longitude)}',
                    style: const TextStyle(fontSize: 14.0, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleMockLocation,
        icon: Icon(_isMocking ? Icons.stop : Icons.play_arrow),
        label: Text(_isMocking ? 'DETENER' : 'INICIAR MOCK', style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _isMocking ? Colors.redAccent : Colors.green[600],
        foregroundColor: Colors.white,
        elevation: 6.0,
      ),
    );
  }
}
