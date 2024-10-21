import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const FlutterBlueApp());
}

class FlutterBlueApp extends StatefulWidget {
  const FlutterBlueApp({super.key});

  @override
  State<FlutterBlueApp> createState() => _FlutterBlueAppState();
}

class _FlutterBlueAppState extends State<FlutterBlueApp> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  late StreamSubscription<BluetoothAdapterState> _adapterStateSubscription;

  @override
  void initState() {
    super.initState();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      setState(() {
        _adapterState = state;
      });
    });
  }

  @override
  void dispose() {
    _adapterStateSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget screen;

    if (_adapterState == BluetoothAdapterState.on) {
      screen = const ScanScreen();
    } else {
      screen = BluetoothOffScreen(adapterState: _adapterState);
    }

    return MaterialApp(
      title: 'Tennis Machine Controller',
      home: screen,
    );
  }
}

class BluetoothOffScreen extends StatelessWidget {
  final BluetoothAdapterState adapterState;

  const BluetoothOffScreen({super.key, required this.adapterState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth Off')),
      body: Center(
        child: Text('Bluetooth is ${adapterState == BluetoothAdapterState.off ? "off" : "unknown"}. Please enable it.'),
      ),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  _ScanScreenState createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus();
  List<BluetoothDevice> devicesList = [];
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? targetCharacteristic;
  bool isScanning = false;
  bool isConnected = false;

  // Pitching settings with default values
  int pitchingSpeed = 0; // Default: 0
  int pitchingSpin = 0; // Default: 0
  int feedRate = 5; // Default: 5
  int verticalAngle = 15; // Default: 15
  bool enableFeeder = false; // Default: false
  bool enablePitcher = false; // Default: false
  bool enablePhysicalInput = false; // Default: false
  bool enableFeederPitcher = false; // Default: false

  // Timer to handle subscription timeout
  Timer? _dataTimeoutTimer;

  @override
  void dispose() {
    _dataTimeoutTimer?.cancel();
    super.dispose();
  }

  void startScan() async {
    setState(() {
      isScanning = true;
      devicesList.clear();
    });

    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 4),
      withServices: [Guid("895ae96b-ebc6-4e31-9193-40a9ae4dd3d8")],
    );

    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (!devicesList.contains(r.device)) {
          setState(() {
            devicesList.add(r.device);
          });
        }
      }
    });

    await Future.delayed(const Duration(seconds: 4));
    await FlutterBluePlus.stopScan();

    setState(() {
      isScanning = false;
    });
  }

  void connectToDevice(BluetoothDevice device) async {
    await device.connect();
    List<BluetoothService> services = await device.discoverServices();

    BluetoothService? targetService;
    for (BluetoothService service in services) {
      for (BluetoothCharacteristic characteristic in service.characteristics) {
        if (characteristic.uuid.toString() == "895ae96b-ebc6-4e31-9193-40a9ae4dd3d8") {
          targetService = service;
          targetCharacteristic = characteristic;
          break;
        }
      }
      if (targetService != null) break;
    }

    if (targetService != null && targetCharacteristic != null) {
      await targetCharacteristic!.setNotifyValue(true);
      
      try {
        // Read initial characteristic value
        var initialValue = await targetCharacteristic!.read();

        if (initialValue.isNotEmpty && initialValue.length >= 7) {
          updateValuesFromData(Uint8List.fromList(initialValue));
        } else {
          // If initial read fails, retain default values
          // Optionally, you can show a message or log this event
          print("Initial read returned empty or insufficient data. Using default values.");
        }
      } catch (e) {
        // Handle read error and retain default values
        print("Error reading initial characteristic value: $e");
      }

      // Set up a timeout to use default values if no data is received within 5 seconds
      _dataTimeoutTimer = Timer(const Duration(seconds: 5), () {
        setState(() {
          // Revert to default values
          pitchingSpeed = 0;
          pitchingSpin = 0;
          feedRate = 5;
          verticalAngle = 15;
          enableFeeder = false;
          enablePitcher = false;
          enablePhysicalInput = false;
        });
        print("No data received within timeout. Using default values.");
      });

      // Subscribe to notifications
      targetCharacteristic!.value.listen((value) {
        if (value.isNotEmpty && value.length >= 7) {
          _dataTimeoutTimer?.cancel(); // Data received, cancel the timeout
          updateValuesFromData(Uint8List.fromList(value));
        } else {
          print("Received empty or insufficient data.");
        }
      }).onError((error) {
        // Handle stream errors
        print("Error in characteristic stream: $error");
      });

      setState(() {
        connectedDevice = device;
        isConnected = true;
      });
    } else {
      await device.disconnect();
      setState(() {
        connectedDevice = null;
        isConnected = false;
      });
      print("Target service or characteristic not found. Device disconnected.");
    }
  }

  void updateValuesFromData(Uint8List data) {
    // Ensure data has at least 7 bytes
    if (data.length < 7) {
      print("Data length is less than expected. Skipping update.");
      return;
    }

    setState(() {
      enablePitcher = data[0] == 1;
      enableFeeder = data[1] == 1;
      enablePhysicalInput = data[2] == 1;
      pitchingSpeed = data[3];
      pitchingSpin = data[4] - 10;
      feedRate = data[5];
      verticalAngle = data[6];
    });
  }

  void disconnectDevice() async {
    _dataTimeoutTimer?.cancel(); // Cancel any existing timeout
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      setState(() {
        connectedDevice = null;
        isConnected = false;
      });
      print("Device disconnected.");
    }
  }

  void writeCommandData() async {
    if (targetCharacteristic != null) {
      Uint8List data = Uint8List(7);
      data[0] = enablePitcher ? 1 : 0;
      data[1] = enableFeeder ? 1 : 0;
      data[2] = enablePhysicalInput ? 1 : 0;
      data[3] = pitchingSpeed;
      data[4] = pitchingSpin + 10;
      data[5] = feedRate;
      data[6] = verticalAngle;
      await targetCharacteristic!.write(data);
      print("Command data written: $data");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tennis Machine Controller')),
      body: Column(
        children: <Widget>[
          ElevatedButton(
            onPressed: isConnected ? disconnectDevice : startScan,
            child: Text(isConnected ? 'Disconnect' : 'Scan'),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: devicesList.isEmpty ? 1 : devicesList.length,
              itemBuilder: (context, index) {
                if (devicesList.isEmpty) {
                  return const ListTile(
                    title: Text('No devices found'),
                  );
                }
                return ListTile(
                  title: Text(devicesList[index].name.isNotEmpty ? devicesList[index].name : "Unknown Device"),
                  subtitle: Text(devicesList[index].id.toString()),
                  onTap: () => connectToDevice(devicesList[index]),
                );
              },
            ),
          ),
          if (isConnected) ...[
            Text("Pitching Speed: $pitchingSpeed"),
            // Pitching Speed Slider
            Slider(
              value: pitchingSpeed.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: pitchingSpeed.toString(),
              onChanged: (value) {
                setState(() {
                  pitchingSpeed = value.toInt();
                });
              },
              onChangeEnd: (value) {
                setState(() {
                  pitchingSpeed = value.toInt();
                });
                writeCommandData();
              },
            ),
            
            Text("Pitching Spin: $pitchingSpin"),
            // Pitching Spin Slider
            Slider(
              value: pitchingSpin.toDouble(),
              min: -10,
              max: 10,
              divisions: 20,
              label: pitchingSpin.toString(),
              onChanged: (value) {
                setState(() {
                  pitchingSpin = value.toInt();
                });
              },
              onChangeEnd: (value) {
                setState(() {
                  pitchingSpin = value.toInt();
                });
                writeCommandData();
              },
            ),
            
            Text("Feeder Rate: $feedRate"),
            // Feeder Rate Slider
            Slider(
              value: feedRate.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: feedRate.toString(),
              onChanged: (value) {
                setState(() {
                  feedRate = value.toInt();
                });
              },
              onChangeEnd: (value) {
                setState(() {
                  feedRate = value.toInt();
                });
                writeCommandData();
              },
            ),
            
            Text("Vertical Angle: $verticalAngle"),
            // Vertical Angle Slider
            Slider(
              value: verticalAngle.toDouble(),
              min: 15,
              max: 50,
              divisions: 7,
              label: verticalAngle.toString(),
              onChanged: (value) {
                setState(() {
                  verticalAngle = value.toInt();
                });
              },
              onChangeEnd: (value) {
                setState(() {
                  verticalAngle = value.toInt();
                });
                writeCommandData();
              },
            ),
            
            
            // Control Switches
            SwitchListTile(
              title: const Text('Enable Pitcher and Feeder'),
              value: enableFeederPitcher,
              onChanged: (value) {
                setState(() {
                  enableFeederPitcher = value;
                  enableFeeder = enableFeederPitcher;
                  enablePitcher = enableFeederPitcher;
                });
                writeCommandData();
              },
            ),
            SwitchListTile(
              title: const Text('Enable Pitcher Only'),
              value: enablePitcher,
              onChanged: (value) {
                setState(() {
                  enablePitcher = value;
                });
                writeCommandData();
              },
            ),
            SwitchListTile(
              title: const Text('Enable Feeder Only'),
              value: enableFeeder,
              onChanged: (value) {
                setState(() {
                  enableFeeder = value;
                });
                writeCommandData();
              },
            ),
            SwitchListTile(
              title: const Text('Enable Physical Input'),
              value: enablePhysicalInput,
              onChanged: (value) {
                setState(() {
                  enablePhysicalInput = value;
                });
                writeCommandData();
              },
            ),
          ]
        ],
      ),
    );
  }
}
