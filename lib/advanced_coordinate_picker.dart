import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:utm/utm.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class AdvancedCoordinatePicker extends StatefulWidget {
  final LatLng initialPosition;

  const AdvancedCoordinatePicker({super.key, required this.initialPosition});

  @override
  State<AdvancedCoordinatePicker> createState() => _AdvancedCoordinatePickerState();
}

class _AdvancedCoordinatePickerState extends State<AdvancedCoordinatePicker> {
  double _latDegrees = 0.0;
  double _lonDegrees = 0.0;
  String _currentAddress = "Sin buscar";
  bool _isSearching = false;

  late TextEditingController _addressController;
  late TextEditingController _decimalLatController;
  late TextEditingController _decimalLonController;

  @override
  void initState() {
    super.initState();
    _latDegrees = widget.initialPosition.latitude;
    _lonDegrees = widget.initialPosition.longitude;

    _addressController = TextEditingController();
    _decimalLatController = TextEditingController(text: _latDegrees.toStringAsFixed(6));
    _decimalLonController = TextEditingController(text: _lonDegrees.toStringAsFixed(6));
  }

  @override
  void dispose() {
    _addressController.dispose();
    _decimalLatController.dispose();
    _decimalLonController.dispose();
    super.dispose();
  }

  Map<String, double> _toDMS(double coordinate, bool isLatitude) {
    double absolute = coordinate.abs();
    int degrees = absolute.truncate();
    double minutesDecimal = (absolute - degrees) * 60;
    int minutes = minutesDecimal.truncate();
    double seconds = (minutesDecimal - minutes) * 60;

    double signedDegrees = isLatitude && coordinate < 0 ? -degrees.toDouble() : degrees.toDouble();
    if (!isLatitude && coordinate < 0) {
      signedDegrees = -degrees.toDouble();
    }

    return {'degrees': signedDegrees, 'minutes': minutes.toDouble(), 'seconds': seconds};
  }

  Map<String, double> _toDDMM(double coordinate, bool isLatitude) {
    double absolute = coordinate.abs();
    int degrees = absolute.truncate();
    double minutesDecimal = (absolute - degrees) * 60;

    double signedDegrees = isLatitude && coordinate < 0 ? -degrees.toDouble() : degrees.toDouble();
    if (!isLatitude && coordinate < 0) {
      signedDegrees = -degrees.toDouble();
    }

    return {'degrees': signedDegrees, 'minutes': minutesDecimal};
  }

  Future<void> _searchAddress() async {
    final query = _addressController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _currentAddress = "Buscando...";
    });

    final Uri url = Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=1');
    
    try {
      final response = await http.get(url, headers: {'User-Agent': 'MockGpsApp/1.4'});
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          setState(() {
            _latDegrees = double.parse(data[0]['lat'].toString());
            _lonDegrees = double.parse(data[0]['lon'].toString());
            _currentAddress = data[0]['display_name'];
            _updateControllersFromState();
            _isSearching = false;
          });
        } else {
          setState(() {
            _currentAddress = "No se encontraron resultados.";
            _isSearching = false;
          });
        }
      }
    } catch (e) {
      setState(() {
        _currentAddress = "Error de conexión.";
        _isSearching = false;
      });
    }
  }

  void _updateControllersFromState() {
    _decimalLatController.text = _latDegrees.toStringAsFixed(6);
    _decimalLonController.text = _lonDegrees.toStringAsFixed(6);
  }

  @override
  Widget build(BuildContext context) {
    final dmsLat = _toDMS(_latDegrees, true);
    final dmsLon = _toDMS(_lonDegrees, false);
    
    final ddmmLat = _toDDMM(_latDegrees, true);
    final ddmmLon = _toDDMM(_lonDegrees, false);

    String utmString = "Error";
    try {
      final utmCoord = UTM.fromLatLon(lat: _latDegrees, lon: _lonDegrees);
      // AQUÍ ESTÁ EL ARREGLO DEFINITIVO: Sin letras, solo la zona segura
      utmString = "Zona ${utmCoord.zone}\n${utmCoord.easting.toStringAsFixed(0)}E ${utmCoord.northing.toStringAsFixed(0)}N";
    } catch (e) {
      utmString = "Fuera de rango UTM";
    }

    return Scaffold(
      backgroundColor: Colors.grey[200],
      appBar: AppBar(
        title: const Text('GPS Convertidor'),
        backgroundColor: Colors.brown[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Usar esta ubicación',
            onPressed: () {
              Navigator.pop(context, LatLng(_latDegrees, _lonDegrees));
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addressController,
                      decoration: const InputDecoration(
                        hintText: 'Buscar dirección...',
                        border: InputBorder.none,
                        icon: Icon(Icons.search),
                      ),
                      onSubmitted: (_) => _searchAddress(),
                    ),
                  ),
                  if (_isSearching)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: _searchAddress,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            
            _buildDataCard(
              title: "DD.dddddd°",
              icon: Icons.public,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _decimalLatController,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      style: const TextStyle(fontSize: 16, color: Colors.blueGrey),
                      onChanged: (val) {
                        final lat = double.tryParse(val);
                        if (lat != null) setState(() => _latDegrees = lat);
                      },
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _decimalLonController,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      style: const TextStyle(fontSize: 16, color: Colors.blueGrey),
                      onChanged: (val) {
                        final lon = double.tryParse(val);
                        if (lon != null) setState(() => _lonDegrees = lon);
                      },
                    ),
                  ),
                ],
              ),
            ),

            _buildDataCard(
              title: "DD°MM.mm'",
              icon: Icons.public,
              child: Column(
                children: [
                  Text("${ddmmLat['degrees']?.toInt()}° ${ddmmLat['minutes']?.toStringAsFixed(4)}'", style: const TextStyle(fontSize: 16, color: Colors.blueGrey)),
                  Text("${ddmmLon['degrees']?.toInt()}° ${ddmmLon['minutes']?.toStringAsFixed(4)}'", style: const TextStyle(fontSize: 16, color: Colors.blueGrey)),
                ],
              ),
            ),

            _buildDataCard(
              title: "DD°MM'SS\"",
              icon: Icons.public,
              child: Column(
                children: [
                  Text("${dmsLat['degrees']?.toInt()}° ${dmsLat['minutes']?.toInt()}' ${dmsLat['seconds']?.toStringAsFixed(2)}\"", style: const TextStyle(fontSize: 16, color: Colors.blueGrey)),
                  Text("${dmsLon['degrees']?.toInt()}° ${dmsLon['minutes']?.toInt()}' ${dmsLon['seconds']?.toStringAsFixed(2)}\"", style: const TextStyle(fontSize: 16, color: Colors.blueGrey)),
                ],
              ),
            ),

            _buildDataCard(
              title: "UTM",
              icon: Icons.map,
              child: Text(utmString, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.blueGrey)),
            ),

            _buildDataCard(
              title: "Dirección",
              icon: Icons.business,
              child: Text(_currentAddress, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Colors.blueGrey)),
            ),
            
            const SizedBox(height: 20),
            
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                ),
                icon: const Icon(Icons.send),
                label: const Text("ENVIAR AL MAPA", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                onPressed: () {
                  Navigator.pop(context, LatLng(_latDegrees, _lonDegrees));
                },
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildDataCard({required String title, required IconData icon, required Widget child}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 100,
              decoration: BoxDecoration(
                color: Colors.brown[200],
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(5), bottomLeft: Radius.circular(5)),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: Colors.brown[900], fontWeight: FontWeight.bold, fontSize: 12)),
                  const Spacer(),
                  Align(alignment: Alignment.bottomRight, child: Icon(icon, color: Colors.brown[500], size: 20)),
                ],
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                alignment: Alignment.center,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
