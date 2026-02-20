// ============================================
// FILE: lib/main.dart
// COMPLETE DUPLICATE IMAGE DETECTION APP
// ============================================

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';


// ==========================================
// ENTRY POINT
// ==========================================

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Duplicate Detector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}


// ==========================================
// IMAGE HASHER - pHash + dHash
// ==========================================

class ImageHasher {

  // ========== pHash (Perceptual Hash) ==========
  //
  // HOW IT WORKS:
  // 1. Shrink image to 8x8
  // 2. Convert to grayscale
  // 3. Find average brightness
  // 4. Each pixel: brighter than average = 1, darker = 0
  // 5. Result: 64 character string of 1s and 0s

  static String generatePHash(Uint8List imageBytes) {
    try {
      // Step 1: Open the image
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) return '';

      // Step 2: Resize to 8x8 (tiny!)
      // This removes all small details
      // Only keeps the basic structure
      img.Image resized = img.copyResize(
        image,
        width: 8,
        height: 8,
        interpolation: img.Interpolation.average,
      );

      // Step 3: Convert to grayscale (remove colors)
      img.Image grayscale = img.grayscale(resized);

      // Step 4: Get all 64 pixel brightness values
      List<int> pixels = [];
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          img.Pixel pixel = grayscale.getPixel(x, y);
          pixels.add(pixel.r.toInt());
        }
      }

      // Step 5: Calculate average brightness
      double average = pixels.reduce((a, b) => a + b) / pixels.length;

      // Step 6: Generate hash
      // Brighter than average = 1
      // Darker than average = 0
      String hash = '';
      for (int pixelValue in pixels) {
        hash += pixelValue > average ? '1' : '0';
      }

      return hash; // 64 characters like "1101001011001010..."

    } catch (e) {
      print('Error generating pHash: $e');
      return '';
    }
  }


  // ========== dHash (Difference Hash) ==========
  //
  // HOW IT WORKS:
  // 1. Shrink image to 9x8 (one extra column)
  // 2. Convert to grayscale
  // 3. Compare each pixel with its RIGHT neighbor
  // 4. Left pixel brighter than right = 1, else = 0
  // 5. Result: 64 character string
  //
  // WHY DIFFERENT FROM pHash?
  // pHash compares each pixel with AVERAGE
  // dHash compares each pixel with its NEIGHBOR
  // They catch different types of duplicates
  // Using both together = more accurate

  static String generateDHash(Uint8List imageBytes) {
    try {
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) return '';

      // Resize to 9x8 (9 wide, 8 tall)
      // We need 9 columns to make 8 comparisons per row
      img.Image resized = img.copyResize(
        image,
        width: 9,
        height: 8,
        interpolation: img.Interpolation.average,
      );

      img.Image grayscale = img.grayscale(resized);

      String hash = '';

      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          // Get current pixel and its right neighbor
          int leftPixel = grayscale.getPixel(x, y).r.toInt();
          int rightPixel = grayscale.getPixel(x + 1, y).r.toInt();

          // Is left brighter than right?
          hash += leftPixel > rightPixel ? '1' : '0';
        }
      }

      return hash; // 64 characters

    } catch (e) {
      print('Error generating dHash: $e');
      return '';
    }
  }


  // ========== Hamming Distance ==========
  //
  // Counts how many characters are DIFFERENT
  // between two hashes
  //
  // "11001100" vs "11001100" → Distance = 0 (same!)
  // "11001100" vs "11001101" → Distance = 1 (1 diff)
  // "11001100" vs "00110011" → Distance = 8 (all diff)

  static int hammingDistance(String hash1, String hash2) {
    if (hash1.length != hash2.length) return 999;
    if (hash1.isEmpty || hash2.isEmpty) return 999;

    int distance = 0;
    for (int i = 0; i < hash1.length; i++) {
      if (hash1[i] != hash2[i]) {
        distance++;
      }
    }
    return distance;
  }


  // ========== Check if Duplicate ==========

  static Map<String, dynamic> checkDuplicate(
      String pHash1, String dHash1,
      String pHash2, String dHash2,
      ) {
    int pDistance = hammingDistance(pHash1, pHash2);
    int dDistance = hammingDistance(dHash1, dHash2);

    double pSimilarity = ((64 - pDistance) / 64) * 100;
    double dSimilarity = ((64 - dDistance) / 64) * 100;
    double avgSimilarity = (pSimilarity + dSimilarity) / 2;

    bool isDuplicate = false;
    String confidence = '';

    if (pDistance <= 3 && dDistance <= 3) {
      isDuplicate = true;
      confidence = 'EXACT DUPLICATE';
    } else if (pDistance <= 5 && dDistance <= 5) {
      isDuplicate = true;
      confidence = 'VERY LIKELY DUPLICATE';
    } else if (pDistance <= 8 && dDistance <= 8) {
      isDuplicate = true;
      confidence = 'PROBABLY DUPLICATE';
    } else if (pDistance <= 12 || dDistance <= 12) {
      isDuplicate = false;
      confidence = 'MAYBE SIMILAR';
    } else {
      isDuplicate = false;
      confidence = 'DIFFERENT';
    }

    return {
      'isDuplicate': isDuplicate,
      'confidence': confidence,
      'pDistance': pDistance,
      'dDistance': dDistance,
      'pSimilarity': pSimilarity,
      'dSimilarity': dSimilarity,
      'avgSimilarity': avgSimilarity,
    };
  }
}


// ==========================================
// HASH STORAGE - Save and Load hashes
// ==========================================

class HashStorage {

  // Save hash to local storage (like a mini database)
  static Future<void> saveHash(String photoId, String pHash, String dHash, String filePath) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    // Get existing hashes
    List<String> storedHashes = prefs.getStringList('photo_hashes') ?? [];

    // Add new hash
    Map<String, String> hashData = {
      'id': photoId,
      'pHash': pHash,
      'dHash': dHash,
      'filePath': filePath,
      'timestamp': DateTime.now().toString(),
    };

    storedHashes.add(jsonEncode(hashData));

    // Save back
    await prefs.setStringList('photo_hashes', storedHashes);
  }

  // Load all stored hashes
  static Future<List<Map<String, dynamic>>> loadAllHashes() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> storedHashes = prefs.getStringList('photo_hashes') ?? [];

    return storedHashes
        .map((hash) => Map<String, dynamic>.from(jsonDecode(hash)))
        .toList();
  }

  // Clear all hashes (for testing)
  static Future<void> clearAll() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('photo_hashes');
  }

  // Get count of stored photos
  static Future<int> getCount() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> storedHashes = prefs.getStringList('photo_hashes') ?? [];
    return storedHashes.length;
  }
}


// ==========================================
// HOME SCREEN - Main UI
// ==========================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  final ImagePicker _picker = ImagePicker();
  List<Map<String, dynamic>> _storedPhotos = [];
  bool _isProcessing = false;
  int _photoCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStoredPhotos();
  }

  // Load previously stored photos
  Future<void> _loadStoredPhotos() async {
    _storedPhotos = await HashStorage.loadAllHashes();
    _photoCount = _storedPhotos.length;
    setState(() {});
  }


  // ===== MAIN FUNCTION: Pick and Check Photo =====

  Future<void> _pickAndCheckPhoto() async {

    // Step 1: Let user pick a photo
    final XFile? pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
    );

    if (pickedFile == null) return; // User cancelled

    setState(() => _isProcessing = true);

    // Step 2: Read image bytes
    Uint8List imageBytes = await File(pickedFile.path).readAsBytes();

    // Step 3: Generate BOTH hashes
    String pHash = ImageHasher.generatePHash(imageBytes);
    String dHash = ImageHasher.generateDHash(imageBytes);

    if (pHash.isEmpty || dHash.isEmpty) {
      // _showErrorDialog('Could not process this image');
      setState(() => _isProcessing = false);
      return;
    }

    // Step 4: Compare with ALL stored photos
    Map<String, dynamic>? bestMatch;
    double bestSimilarity = 0;

    for (var storedPhoto in _storedPhotos) {
      var result = ImageHasher.checkDuplicate(
        pHash, dHash,
        storedPhoto['pHash'], storedPhoto['dHash'],
      );

      if (result['avgSimilarity'] > bestSimilarity) {
        bestSimilarity = result['avgSimilarity'];
        bestMatch = {
          ...result,
          'matchedWith': storedPhoto,
        };
      }
    }

    setState(() => _isProcessing = false);

    // Step 5: Show result
    if (bestMatch != null && bestMatch['isDuplicate'] == true) {
      // DUPLICATE FOUND! Show popup
      _showDuplicateDialog(
        pickedFile.path,
        pHash,
        dHash,
        imageBytes,
        bestMatch,
      );
    } else {
      // NO DUPLICATE - Save and upload
      _showNoDuplicateDialog(
        pickedFile.path,
        pHash,
        dHash,
        imageBytes,
        bestMatch,
      );
    }
  }


  // ===== Pick MULTIPLE Photos =====

  Future<void> _pickMultiplePhotos() async {

    final List<XFile> pickedFiles = await _picker.pickMultiImage();

    if (pickedFiles.isEmpty) return;

    setState(() => _isProcessing = true);

    List<Map<String, dynamic>> results = [];
    List<Map<String, dynamic>> newPhotoHashes = [];

    // Generate hashes for all selected photos
    for (int i = 0; i < pickedFiles.length; i++) {
      Uint8List bytes = await File(pickedFiles[i].path).readAsBytes();
      String pHash = ImageHasher.generatePHash(bytes);
      String dHash = ImageHasher.generateDHash(bytes);

      newPhotoHashes.add({
        'index': i,
        'path': pickedFiles[i].path,
        'pHash': pHash,
        'dHash': dHash,
        'bytes': bytes,
      });
    }

    // Check 1: Compare selected photos WITH EACH OTHER
    for (int i = 0; i < newPhotoHashes.length; i++) {
      for (int j = i + 1; j < newPhotoHashes.length; j++) {
        var result = ImageHasher.checkDuplicate(
          newPhotoHashes[i]['pHash'], newPhotoHashes[i]['dHash'],
          newPhotoHashes[j]['pHash'], newPhotoHashes[j]['dHash'],
        );

        if (result['isDuplicate'] == true) {
          results.add({
            'type': 'AMONG SELECTED',
            'photo1': 'Photo ${i + 1}',
            'photo2': 'Photo ${j + 1}',
            'similarity': result['avgSimilarity'],
            'confidence': result['confidence'],
          });
        }
      }
    }

    // Check 2: Compare with EXISTING stored photos
    for (int i = 0; i < newPhotoHashes.length; i++) {
      for (var stored in _storedPhotos) {
        var result = ImageHasher.checkDuplicate(
          newPhotoHashes[i]['pHash'], newPhotoHashes[i]['dHash'],
          stored['pHash'], stored['dHash'],
        );

        if (result['isDuplicate'] == true) {
          results.add({
            'type': 'ALREADY EXISTS',
            'photo1': 'Photo ${i + 1}',
            'photo2': 'Stored: ${stored['id']}',
            'similarity': result['avgSimilarity'],
            'confidence': result['confidence'],
          });
        }
      }
    }

    setState(() => _isProcessing = false);

    // Show results
    _showMultipleResults(results, newPhotoHashes);
  }


  // ===== DIALOGS =====

  void _showDuplicateDialog(
      String filePath,
      String pHash,
      String dHash,
      Uint8List imageBytes,
      Map<String, dynamic> matchInfo,
      ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text('Duplicate Found!'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Show the selected image
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(filePath),
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 12),

              _infoRow('Status', matchInfo['confidence']),
              _infoRow('Similarity', '${matchInfo['avgSimilarity'].toStringAsFixed(1)}%'),
              _infoRow('pHash Distance', '${matchInfo['pDistance']}'),
              _infoRow('dHash Distance', '${matchInfo['dDistance']}'),

              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 8),

              const Text(
                'Matched with:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('ID: ${matchInfo['matchedWith']['id']}'),
              Text('Uploaded: ${matchInfo['matchedWith']['timestamp']}'),

              // Show matched image if file exists
              if (File(matchInfo['matchedWith']['filePath']).existsSync())
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(matchInfo['matchedWith']['filePath']),
                      height: 150,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _savePhoto(filePath, pHash, dHash);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Upload Anyway'),
          ),
        ],
      ),
    );
  }


  void _showNoDuplicateDialog(
      String filePath,
      String pHash,
      String dHash,
      Uint8List imageBytes,
      Map<String, dynamic>? closestMatch,
      ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 28),
            SizedBox(width: 8),
            Text('No Duplicate!'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(filePath),
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 12),
              const Text('This image is unique!'),
              const SizedBox(height: 8),
              _infoRow('pHash', pHash.substring(0, 20) + '...'),
              _infoRow('dHash', dHash.substring(0, 20) + '...'),
              if (closestMatch != null)
                _infoRow(
                  'Closest match',
                  '${closestMatch['avgSimilarity']?.toStringAsFixed(1) ?? 'N/A'}%',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _savePhoto(filePath, pHash, dHash);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
  }


  void _showMultipleResults(
      List<Map<String, dynamic>> duplicates,
      List<Map<String, dynamic>> newPhotos,
      ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          duplicates.isEmpty
              ? '✅ No Duplicates Found!'
              : '⚠️ ${duplicates.length} Duplicates Found!',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Selected: ${newPhotos.length} photos'),
              Text('Duplicates: ${duplicates.length}'),
              const Divider(),

              if (duplicates.isEmpty)
                const Text('All photos are unique! Safe to upload.'),

              ...duplicates.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Card(
                  color: Colors.red[50],
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d['type'],
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.red,
                          ),
                        ),
                        Text('${d['photo1']} ↔ ${d['photo2']}'),
                        Text('Similarity: ${d['similarity'].toStringAsFixed(1)}%'),
                        Text('${d['confidence']}'),
                      ],
                    ),
                  ),
                ),
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (duplicates.isNotEmpty)
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                // Upload only unique photos
                // (skip duplicates)
                for (var photo in newPhotos) {
                  await _savePhoto(
                    photo['path'],
                    photo['pHash'],
                    photo['dHash'],
                  );
                }
                _loadStoredPhotos();
              },
              child: const Text('Upload All Anyway'),
            ),
          if (duplicates.isEmpty)
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                for (var photo in newPhotos) {
                  await _savePhoto(
                    photo['path'],
                    photo['pHash'],
                    photo['dHash'],
                  );
                }
                _loadStoredPhotos();
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Upload All'),
            ),
        ],
      ),
    );
  }


  // ===== SAVE PHOTO =====

  Future<void> _savePhoto(String filePath, String pHash, String dHash) async {
    String photoId = 'photo_${DateTime.now().millisecondsSinceEpoch}';

    await HashStorage.saveHash(photoId, pHash, dHash, filePath);

    await _loadStoredPhotos();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Photo uploaded successfully! ✅'),
        backgroundColor: Colors.green,
      ),
    );
  }


  // ===== HELPER WIDGETS =====

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }


  // ===== BUILD UI =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicate Detector'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          // Clear all button (for testing)
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: () async {
              await HashStorage.clearAll();
              await _loadStoredPhotos();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('All data cleared!')),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ===== STATUS BAR =====
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.blue[50],
            child: Column(
              children: [
                Text(
                  '$_photoCount photos stored',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text('Upload a photo to check for duplicates'),
              ],
            ),
          ),

          // ===== PROCESSING INDICATOR =====
          if (_isProcessing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 8),
                  Text('Generating hashes and checking...'),
                ],
              ),
            ),

          // ===== STORED PHOTOS LIST =====
          Expanded(
            child: _storedPhotos.isEmpty
                ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_library, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No photos yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  Text('Tap + to add your first photo'),
                ],
              ),
            )
                : ListView.builder(
              itemCount: _storedPhotos.length,
              itemBuilder: (context, index) {
                var photo = _storedPhotos[index];
                String filePath = photo['filePath'] ?? '';
                bool fileExists = File(filePath).existsSync();

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    leading: fileExists
                        ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(filePath),
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                    )
                        : const Icon(Icons.image, size: 50),
                    title: Text(photo['id'] ?? 'Unknown'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'pH: ${(photo['pHash'] ?? '').toString().substring(0, 16)}...',
                          style: const TextStyle(fontSize: 11),
                        ),
                        Text(
                          'dH: ${(photo['dHash'] ?? '').toString().substring(0, 16)}...',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                    trailing: Text(
                      '#${index + 1}',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),

      // ===== BOTTOM BUTTONS =====
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Single photo button
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _pickAndCheckPhoto,
                icon: const Icon(Icons.add_a_photo),
                label: const Text('Single Photo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Multiple photos button
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _pickMultiplePhotos,
                icon: const Icon(Icons.photo_library),
                label: const Text('Multiple Photos'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}