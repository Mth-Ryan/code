/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 elementary Code contributors
 */

public class Scratch.Services.SymbolIndex : Object {
    private Sqlite.Database database;
    private Gee.ArrayList<string> roots = new Gee.ArrayList<string> ();
    private Gee.Queue<string> directories = new Gee.LinkedList<string> ();
    private Gee.Queue<string> files = new Gee.LinkedList<string> ();
    private Gee.HashSet<string> seen_files = new Gee.HashSet<string> ();
    private bool indexing = false;
    private bool full_scan = false;
    private int total = 0;
    private int completed = 0;

    public signal void file_updated (string path, Gee.ArrayList<Widgets.SymbolPickerTag> tags);
    public signal void index_state_changed (bool active, bool full, int completed, int total);

    public SymbolIndex () {
        var cache_directory = Path.build_filename (Environment.get_user_cache_dir (), "io.elementary.code");
        DirUtils.create_with_parents (cache_directory, 0700);
        var cache_path = Path.build_filename (cache_directory, "symbol-index.sqlite3");
        if (Sqlite.Database.open (cache_path, out database) != Sqlite.OK) {
            warning ("Unable to open symbol cache: %s", database.errmsg ());
            return;
        }

        database.busy_timeout (3000);
        database.exec ("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        database.exec ("CREATE TABLE IF NOT EXISTS projects (path TEXT PRIMARY KEY, scanned INTEGER NOT NULL DEFAULT 0);");
        database.exec ("CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, project TEXT NOT NULL, hash TEXT NOT NULL DEFAULT '', invalidated INTEGER NOT NULL DEFAULT 1);");
        database.exec ("CREATE INDEX IF NOT EXISTS files_project_idx ON files(project);");
        database.exec ("CREATE TABLE IF NOT EXISTS tags (path TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, scope TEXT NOT NULL DEFAULT '', line INTEGER NOT NULL, PRIMARY KEY(path,name,kind,line));");
        database.exec ("CREATE INDEX IF NOT EXISTS tags_name_idx ON tags(name);");
    }

    public Gee.ArrayList<Widgets.SymbolPickerTag> get_cached_tags (string[] project_roots) {
        var result = new Gee.ArrayList<Widgets.SymbolPickerTag> ();
        if (database == null) {
            return result;
        }

        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT tags.name, tags.kind, tags.scope, tags.line, tags.path FROM tags JOIN files ON files.path=tags.path WHERE files.project=? ORDER BY tags.name COLLATE NOCASE", -1, out statement) != Sqlite.OK) {
            return result;
        }

        foreach (var root in project_roots) {
            statement.bind_text (1, root);
            while (statement.step () == Sqlite.ROW) {
                result.add (new Widgets.SymbolPickerTag (
                    statement.column_text (0) ?? "",
                    statement.column_text (1) ?? "",
                    statement.column_text (2) ?? "",
                    statement.column_int (3),
                    statement.column_text (4) ?? ""
                ));
            }
            statement.reset ();
            statement.clear_bindings ();
        }

        return result;
    }

    public void invalidate_file (string path) {
        if (database == null || path == "") {
            return;
        }

        var project = project_for_path (path);
        if (project == "") {
            foreach (var root in new GLib.Settings ("io.elementary.code.folder-manager").get_strv ("opened-folders")) {
                if (path.has_prefix (root + Path.DIR_SEPARATOR_S) && root.length > project.length) {
                    project = root;
                }
            }
        }
        if (project != "") {
            Sqlite.Statement insert;
            if (database.prepare_v2 ("INSERT INTO files(path,project,hash,invalidated) VALUES(?,?, '',1) ON CONFLICT(path) DO UPDATE SET invalidated=1, project=excluded.project", -1, out insert) == Sqlite.OK) {
                insert.bind_text (1, path);
                insert.bind_text (2, project);
                insert.step ();
            }
        }

        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE files SET invalidated=1 WHERE path=?", -1, out statement) == Sqlite.OK) {
            statement.bind_text (1, path);
            statement.step ();
        }
    }

    public void start (string[] project_roots, bool recheck_all = false) {
        if (database == null || indexing) {
            return;
        }

        roots.clear ();
        foreach (var root in project_roots) {
            if (FileUtils.test (root, FileTest.IS_DIR) && !roots.contains (root)) {
                roots.add (root);
            }
        }
        if (roots.size == 0) {
            return;
        }

        full_scan = recheck_all;
        indexing = true;
        completed = 0;
        total = 0;
        directories.clear ();
        files.clear ();
        seen_files.clear ();

        if (full_scan) {
            foreach (var root in roots) {
                directories.offer (root);
            }
            set_state (true);
            Idle.add (walk_one_directory);
        } else {
            add_unscanned_projects ();
            set_state (true);
            if (directories.is_empty) {
                add_invalidated_files ();
                count_pending_files ();
                Idle.add (process_one_file);
            } else {
                Idle.add (walk_one_directory);
            }
        }
    }

    private bool walk_one_directory () {
        if (!indexing) {
            return Source.REMOVE;
        }

        var path = directories.poll ();
        if (path == null) {
            finish_full_walk ();
            return Source.REMOVE;
        }

        try {
            var dir = Dir.open (path);
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name == "." || name == ".." || name.has_prefix (".")) {
                    continue;
                }

                var child_path = Path.build_filename (path, name);
                try {
                    var info = File.new_for_path (child_path).query_info ("standard::type,standard::is-hidden,standard::is-backup,standard::content-type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                    if (info.get_file_type () == FileType.DIRECTORY) {
                        directories.offer (child_path);
                    } else if (Utils.check_if_valid_text_file (child_path, info)) {
                        files.offer (child_path);
                        seen_files.add (child_path);
                        total++;
                    }
                } catch (Error e) {
                    debug ("Could not inspect file %s: %s", child_path, e.message);
                }
            }
        } catch (Error e) {
            debug ("Could not index directory %s: %s", path, e.message);
        }

        set_state (true);
        return Source.CONTINUE;
    }

    private void finish_full_walk () {
        prune_missing_files ();
        foreach (var root in roots) {
            set_project_scanned (root);
        }
        total = (int) files.size;
        set_state (true);
        Idle.add (process_one_file);
    }

    private bool process_one_file () {
        if (!indexing) {
            return Source.REMOVE;
        }

        var path = files.poll ();
        if (path == null) {
            indexing = false;
            set_state (false);
            return Source.REMOVE;
        }

        try {
            var project = project_for_path (path);
            if (project != "") {
                index_file (path, project, full_scan);
            }
        } catch (Error e) {
            debug ("Could not index symbols in %s: %s", path, e.message);
        }

        completed++;
        if (completed % 10 == 0 || files.is_empty) {
            set_state (true);
        }
        return Source.CONTINUE;
    }

    private void index_file (string path, string project, bool check_hash) throws Error {
        uint8[] contents;
        string etag;
        File.new_for_path (path).load_contents (null, out contents, out etag);
        var hash = Checksum.compute_for_data (ChecksumType.SHA256, contents);
        var old_hash = "";
        var invalidated = true;
        Sqlite.Statement existing;
        if (database.prepare_v2 ("SELECT hash, invalidated FROM files WHERE path=?", -1, out existing) == Sqlite.OK) {
            existing.bind_text (1, path);
            if (existing.step () == Sqlite.ROW) {
                old_hash = existing.column_text (0) ?? "";
                invalidated = existing.column_int (1) != 0;
            }
        }

        if (check_hash && !invalidated && old_hash == hash) {
            return;
        }

        var subprocess = new Subprocess (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE,
            "ctags", "-f", "-", "--format=2", "--excmd=n", "--fields=nstK", "--extra=", "--sort=no", path
        );
        string output;
        string error_output;
        subprocess.communicate_utf8 (null, null, out output, out error_output);
        var parsed = parse_ctags_output (output, path);
        save_file_tags (path, project, hash, parsed);
        file_updated (path, parsed);
    }

    private Gee.ArrayList<Widgets.SymbolPickerTag> parse_ctags_output (string output, string path) {
        var result = new Gee.ArrayList<Widgets.SymbolPickerTag> ();
        foreach (var line_text in output.split ("\n")) {
            var fields = line_text.split ("\t");
            if (fields.length < 5 || !fields[4].has_prefix ("line:")) {
                continue;
            }
            var line = int.parse (fields[4].substring (5));
            if (line < 1) {
                continue;
            }
            var scope = "";
            if (fields.length > 5) {
                var separator = fields[5].index_of_char (':');
                if (separator >= 0 && separator + 1 < fields[5].length) {
                    scope = fields[5].substring (separator + 1);
                }
            }
            result.add (new Widgets.SymbolPickerTag (fields[0], fields[3], scope, line, path));
        }
        return result;
    }

    private void save_file_tags (string path, string project, string hash, Gee.ArrayList<Widgets.SymbolPickerTag> parsed) {
        database.exec ("BEGIN IMMEDIATE");
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO files(path,project,hash,invalidated) VALUES(?,?,?,0) ON CONFLICT(path) DO UPDATE SET project=excluded.project, hash=excluded.hash, invalidated=0", -1, out statement) == Sqlite.OK) {
            statement.bind_text (1, path);
            statement.bind_text (2, project);
            statement.bind_text (3, hash);
            statement.step ();
        }
        if (database.prepare_v2 ("DELETE FROM tags WHERE path=?", -1, out statement) == Sqlite.OK) {
            statement.bind_text (1, path);
            statement.step ();
        }
        if (database.prepare_v2 ("INSERT OR REPLACE INTO tags(path,name,kind,scope,line) VALUES(?,?,?,?,?)", -1, out statement) == Sqlite.OK) {
            foreach (var tag in parsed) {
                statement.bind_text (1, path);
                statement.bind_text (2, tag.name);
                statement.bind_text (3, tag.kind);
                statement.bind_text (4, tag.scope);
                statement.bind_int (5, tag.line);
                statement.step ();
                statement.reset ();
                statement.clear_bindings ();
            }
        }
        database.exec ("COMMIT");
    }

    private void add_unscanned_projects () {
        var has_unscanned_project = false;
        foreach (var root in roots) {
            Sqlite.Statement statement;
            var scanned = false;
            if (database.prepare_v2 ("SELECT scanned FROM projects WHERE path=?", -1, out statement) == Sqlite.OK) {
                statement.bind_text (1, root);
                scanned = statement.step () == Sqlite.ROW && statement.column_int (0) != 0;
            }
            if (!scanned) {
                has_unscanned_project = true;
            }
        }
        if (has_unscanned_project) {
            foreach (var root in roots) {
                directories.offer (root);
            }
        }
        if (!directories.is_empty) {
            full_scan = true;
        }
    }

    private void add_invalidated_files () {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT path FROM files WHERE invalidated=1", -1, out statement) != Sqlite.OK) {
            return;
        }
        while (statement.step () == Sqlite.ROW) {
            var path = statement.column_text (0) ?? "";
            if (path != "" && project_for_path (path) != "") {
                files.offer (path);
            }
        }
    }

    private void count_pending_files () {
        total = (int) files.size;
    }

    private void set_project_scanned (string root) {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO projects(path,scanned) VALUES(?,1) ON CONFLICT(path) DO UPDATE SET scanned=1", -1, out statement) == Sqlite.OK) {
            statement.bind_text (1, root);
            statement.step ();
        }
    }

    private void prune_missing_files () {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT path FROM files", -1, out statement) != Sqlite.OK) {
            return;
        }
        var missing = new Gee.ArrayList<string> ();
        while (statement.step () == Sqlite.ROW) {
            var path = statement.column_text (0) ?? "";
            if (project_for_path (path) != "" && !seen_files.contains (path)) {
                missing.add (path);
            }
        }
        foreach (var path in missing) {
            Sqlite.Statement remove;
            if (database.prepare_v2 ("DELETE FROM files WHERE path=?", -1, out remove) == Sqlite.OK) {
                remove.bind_text (1, path);
                remove.step ();
            }
            if (database.prepare_v2 ("DELETE FROM tags WHERE path=?", -1, out remove) == Sqlite.OK) {
                remove.bind_text (1, path);
                remove.step ();
            }
            file_updated (path, new Gee.ArrayList<Widgets.SymbolPickerTag> ());
        }
    }

    private string project_for_path (string path) {
        foreach (var root in roots) {
            if (path.has_prefix (root + Path.DIR_SEPARATOR_S)) {
                return root;
            }
        }
        return "";
    }

    private void set_state (bool active) {
        index_state_changed (active, full_scan, completed, total);
    }
}
