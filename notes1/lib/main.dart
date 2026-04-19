import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'firebase_options.dart';

/// ===================== MODEL =====================
class Note {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  factory Note.fromMap(Map<String, dynamic> map) {
    final raw = map['createdAt'];
    DateTime date;

    if (raw is Timestamp) {
      date = raw.toDate();
    } else if (raw is String) {
      date = DateTime.parse(raw);
    } else {
      date = DateTime.now();
    }

    return Note(
      id: map['id'],
      title: map['title'],
      content: map['content'],
      createdAt: date,
    );
  }
}

/// ===================== LOCAL STORAGE =====================
class LocalStorageService {
  Future<File> get _file async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/notes.json');
  }

  Future<List<Note>> load() async {
    try {
      final file = await _file;
      if (!await file.exists()) return [];

      final data = json.decode(await file.readAsString());

      return List<Map<String, dynamic>>.from(data)
          .map((e) => Note.fromMap(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Note> notes) async {
    final file = await _file;

    final jsonData = notes
        .map((n) => {
              ...n.toMap(),
              'createdAt': n.createdAt.toIso8601String(),
            })
        .toList();

    await file.writeAsString(json.encode(jsonData));
  }
}

/// ===================== FIREBASE =====================
class FirebaseService {
  final _db = FirebaseFirestore.instance;

  Future<List<Note>> fetch() async {
    final snap = await _db
        .collection('notes')
        .orderBy('createdAt', descending: true)
        .get();

    return snap.docs.map((e) => Note.fromMap(e.data())).toList();
  }

  Future<void> save(Note note) async {
    await _db.collection('notes').doc(note.id).set(note.toMap());
  }

  Future<void> delete(String id) async {
    await _db.collection('notes').doc(id).delete();
  }
}

/// ===================== CONTROLLER =====================
class NotesController extends ChangeNotifier {
  final _local = LocalStorageService();
  final _firebase = FirebaseService();
  final _uuid = const Uuid();

  List<Note> _notes = [];
  bool _syncing = false;

  List<Note> get notes => _notes;
  bool get syncing => _syncing;

  Future<void> init() async {
    _notes = await _local.load();
    notifyListeners();
    await sync();
  }

  Future<void> add(String title, String content) async {
    final note = Note(
      id: _uuid.v4(),
      title: title,
      content: content,
      createdAt: DateTime.now(),
    );

    _notes.insert(0, note);
    notifyListeners();

    await _local.save(_notes);
    await _firebase.save(note);
  }

  Future<void> delete(String id) async {
    _notes.removeWhere((e) => e.id == id);
    notifyListeners();

    await _local.save(_notes);
    await _firebase.delete(id);
  }

  Future<void> sync() async {
    _syncing = true;
    notifyListeners();

    final remote = await _firebase.fetch();
    final ids = _notes.map((e) => e.id).toSet();

    for (var n in remote) {
      if (!ids.contains(n.id)) {
        _notes.add(n);
      }
    }

    _notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    await _local.save(_notes);

    _syncing = false;
    notifyListeners();
  }
}

/// ===================== MAIN =====================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Daily Notes",
      home: NotesProvider(
        controller: NotesController(),
        child: const NotesScreen(),
      ),
    );
  }
}

/// ===================== PROVIDER =====================
class NotesProvider extends InheritedNotifier<NotesController> {
  const NotesProvider({
    super.key,
    required NotesController controller,
    required super.child,
  }) : super(notifier: controller);

  static NotesController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NotesProvider>()!.notifier!;
}

/// ===================== LIST SCREEN =====================
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    NotesProvider.of(context).init();
  }

  @override
  Widget build(BuildContext context) {
    final controller = NotesProvider.of(context);
    final isWide = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Daily Notes"),
        actions: [
          if (controller.syncing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            )
        ],
      ),
      body: controller.notes.isEmpty
          ? const Center(child: Text("No Notes"))
          : isWide
              ? GridView.count(
                  crossAxisCount: 2,
                  children:
                      controller.notes.map(_buildCard).toList(),
                )
              : ListView(
                  children:
                      controller.notes.map(_buildCard).toList(),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addNote(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildCard(Note note) {
    final controller = NotesProvider.of(context);

    return Dismissible(
      key: Key(note.id),
      onDismissed: (_) => controller.delete(note.id),
      child: ListTile(
        title: Text(note.title),
        subtitle: Text(
          note.content,
          maxLines: 1,
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DetailScreen(note: note),
          ),
        ),
      ),
    );
  }

  void _addNote(BuildContext context) {
    final title = TextEditingController();
    final content = TextEditingController();

    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: "Title")),
            TextField(controller: content, decoration: const InputDecoration(labelText: "Content")),
            ElevatedButton(
              onPressed: () {
                NotesProvider.of(context).add(
                  title.text,
                  content.text,
                );
                Navigator.pop(context);
              },
              child: const Text("Save"),
            )
          ],
        ),
      ),
    );
  }
}

/// ===================== DETAIL =====================
class DetailScreen extends StatelessWidget {
  final Note note;

  const DetailScreen({super.key, required this.note});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(note.title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          note.content,
          style: const TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
