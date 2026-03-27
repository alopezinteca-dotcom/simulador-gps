import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:utm/utm.dart';
import 'dart:convert';

void main() {
  runApp(const MockLocationApp());
}

/// MÓDULO 1: Aplicación Principal
class MockLocationApp extends StatelessWidget {
  const MockLocationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mock GPS App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
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
      debugPrint("Error al iniciar Mock Location: \$e");
      return false;
    }
  }

  Future<bool> stopMocking() async {
    try {
      await _channel.invokeMethod('stopMocking');
      return true;
    } catch (e) {
      debugPrint("Error al detener Mock Location: \$e");
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
        'https://nominatim.openstreetmap.org/search?q=\$query&format=json&limit=1');
    
    try {
      final response = await http.get(
        url, 
        headers: {
          'User-Agent': 'MockGpsApp/1.2',
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
      debugPrint("Error en la búsqueda de dirección: \$e");
    }
    return null;
  }
}

/// MÓDULO 4: Formateador y Conversor de Coordenadas
class CoordinateFormatter {
  
  static double enforce7Decimals(double value) {
    return double.parse(value.toStringAsFixed(7));
  }

  static String toGMS(double coordinate, bool isLatitude) {
    String direction = "";
    if (isLatitude) {
      if (coordinate >= 0) {
        direction = "N";
      } else {
        direction = "S";
      }
    } else {
      if (coordinate >= 0) {
        direction = "E";
      } else {
        direction = "O";
      }
    }
    
    double absolute = coordinate.abs();
    int degrees = absolute.truncate();
    double minutesDecimal = (absolute - degrees) * 60;
    int minutes = minutesDecimal.truncate();
    double seconds = (minutesDecimal - minutes) * 60;

    return "\$degrees° \$minutes' \${seconds.toStringAsFixed(2)}\" \$direction";
  }

  static String toUTMString(double lat, double lng) {
    try {
      final UTM utmCoord = UTM.fromLatLon(lat: lat, lon: lng);
      return "Zona \${utmCoord.zone}\${utmCoord.letter}, E: \${utmCoord.easting.toStringAsFixed(2)}, N: \${utmCoord.northing.toStringAsFixed(2)}";
    } catch (e) {
      return "Error en conversión UTM";
    }
  }
}

/// MÓDULO 6: Servicio de Ajustes del Sistema
class SystemSettingsService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');

  Future<bool> openTimeSettings() async {
    try {
      await _channel.invokeMethod('openTimeSettings');
      return true;
    } catch (e) {
      debugPrint("Error al abrir ajustes de hora: \$e");
      return false;
    }
  }
}

/// MÓDULO 5: Pantalla Principal y Mapa
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
    
    if (query.isEmpty) {
      return;
    }

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
            const SnackBar(content: Text('Simulación de GPS detenida.')),
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
            SnackBar(content: Text('Simulando en: \$lat7, \$lng7')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error. ¿Activaste la app en Opciones de Desarrollador?'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    }
  }

  void _showCoordinatesMenu() {
    
    final double lat7 = CoordinateFormatter.enforce7Decimals(_selectedPosition.latitude);
    final double lng7 = CoordinateFormatter.enforce7Decimals(_selectedPosition.longitude);
    
    final String decimalFormat = "\$lat7, \$lng7";
    final String gmsFormat = "\${CoordinateFormatter.toGMS(lat7, true)}, \${CoordinateFormatter.toGMS(lng7, false)}";
    final String utmFormat = CoordinateFormatter.toUTMString(lat7, lng7);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.0)),
      ),
      builder: (BuildContext context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Formatos de Coordenadas',
                style: TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
              ),
              const Divider(),
              ListTile(
                title: const Text('Decimales (7 máx)'),
                subtitle: Text(decimalFormat),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: decimalFormat));
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copiado al portapapeles')),
                    );
                  },
                ),
              ),
              ListTile(
                title: const Text('GMS (Grados Min Seg)'),
                subtitle: Text(gmsFormat),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: gmsFormat));
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copiado al portapapeles')),
                    );
                  },
                ),
              ),
              ListTile(
                title: const Text('UTM'),
                subtitle: Text(utmFormat),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: utmFormat));
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copiado al portapapeles')),
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Simulador GPS Pro'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.access_time),
            tooltip: 'Cambiar Hora del Sistema',
            onPressed: () async {
              await _systemSettingsService.openTimeSettings();
            },
          ),
          IconButton(
            icon: const Icon(Icons.share_location),
            tooltip: 'Ver/Copiar coordenadas',
            onPressed: _showCoordinatesMenu,
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
                    width: 50.0,
                    height: 50.0,
                    child: const Icon(
                      Icons.location_crosshairs,
                      color: Colors.red,
                      size: 50.0,
                    ),
                  ),
                ],
              ),
            ],
          ),
          
          Positioned(
            top: 16.0,
            left: 16.0,
            right: 16.0,
            child: Card(
              elevation: 4.0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: 'Buscar ciudad o calle...',
                          border: InputBorder.none,
                          icon: Icon(Icons.search),
                        ),
                        onSubmitted: (_) {
                          _performSearch();
                        },
                      ),
                    ),
                    if (_isLoadingSearch)
                      const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: SizedBox(
                          width: 24.0,
                          height: 24.0,
                          child: CircularProgressIndicator(strokeWidth: 2.0),
                        ),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: _performSearch,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleMockLocation,
        icon: Icon(_isMocking ? Icons.stop : Icons.play_arrow),
        label: Text(_isMocking ? 'Detener' : 'Iniciar Mock'),
        backgroundColor: _isMocking ? Colors.red : Colors.green,
        foregroundColor: Colors.white,
      ),
    );
  }
}
