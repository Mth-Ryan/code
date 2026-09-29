/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 elementary Code contributors
 */

public class Scratch.Widgets.SymbolPickerTag : Object {
    public string name { get; construct; }
    public string kind { get; construct; }
    public string scope { get; construct; }
    public int line { get; construct; }
    public string path { get; construct; }

    public SymbolPickerTag (string name, string kind, string scope, int line, string path = "") {
        Object (name: name, kind: kind, scope: scope, line: line, path: path);
    }
}

private class Scratch.Widgets.SymbolPickerRow : Gtk.ListBoxRow {
    public SymbolPickerTag tag { get; construct; }
    public int score { get; construct; }

    public SymbolPickerRow (SymbolPickerTag tag, int score) {
        Object (tag: tag, score: score);

        get_style_context ().add_class ("fuzzy-item");
        get_style_context ().add_class ("flat");

        var icon_name = "lang-method";
        switch (tag.kind.down ()) {
            case "class":
            case "interface":
                icon_name = "lang-class";
                break;
            case "struct":
                icon_name = "lang-struct";
                break;
            case "enum":
                icon_name = "lang-enum";
                break;
            case "constant":
            case "macro":
            case "enumerator":
                icon_name = "lang-constant";
                break;
            case "member":
            case "field":
            case "property":
            case "variable":
                icon_name = "lang-property";
                break;
        }

        var icon = new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.DND);
        icon.get_style_context ().add_class ("fuzzy-file-icon");

        var title = new Gtk.Label (tag.name) {
            halign = Gtk.Align.START,
            ellipsize = Pango.EllipsizeMode.MIDDLE
        };

        var location = tag.path != "" ? "%s:%d".printf (Path.get_basename (tag.path), tag.line) : "%d".printf (tag.line);
        var details = tag.scope != ""
            ? "%s · %s · %s".printf (tag.scope, tag.kind, location)
            : "%s · %s".printf (tag.kind, location);
        var subtitle = new Gtk.Label (details) {
            halign = Gtk.Align.START,
            ellipsize = Pango.EllipsizeMode.MIDDLE
        };
        subtitle.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        subtitle.get_style_context ().add_class (Granite.STYLE_CLASS_SMALL_LABEL);

        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1) {
            valign = Gtk.Align.CENTER
        };
        labels.add (title);
        labels.add (subtitle);

        var row_content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 1) {
            valign = Gtk.Align.CENTER
        };
        row_content.add (icon);
        row_content.add (labels);
        child = row_content;
    }
}

private class Scratch.Widgets.SymbolPickerMatch : Object {
    public SymbolPickerTag tag { get; construct; }
    public int score { get; construct; }

    public SymbolPickerMatch (SymbolPickerTag tag, int score) {
        Object (tag: tag, score: score);
    }
}

public class Scratch.Widgets.SymbolPickerPopover : Gtk.Popover {
    private Gtk.SearchEntry search_entry;
    private Gtk.ListBox result_list;
    private Gtk.Label status_label;
    private Gee.ArrayList<SymbolPickerTag> tags;
    private Gtk.Spinner? spinner;
    private Gtk.Button? reindex_button;
    private Gtk.Widget? global_header;
    private Gtk.Widget? global_status;
    private string[] project_roots = {};
    private bool is_indexing = false;
    private ulong file_updated_handler = 0;
    private ulong index_state_handler = 0;
    private uint results_update_timeout = 0;
    private GLib.Subprocess current_subprocess;
    private string temporary_directory = "";
    private bool is_destroyed = false;

    public SymbolPickerPopover (Scratch.Services.Document? document, Gtk.Widget relative_to,
                                Scratch.Services.SymbolIndex? symbol_index = null,
                                Scratch.Widgets.DocumentView? document_view = null) {
        Object (
            document: document,
            symbol_index: symbol_index,
            document_view: document_view,
            relative_to: relative_to,
            modal: true,
            position: Gtk.PositionType.BOTTOM,
            width_request: 560
        );
        pointing_to = { relative_to.get_allocated_width () / 2, 32, 1, 1 };
    }

    construct {
        tags = new Gee.ArrayList<SymbolPickerTag> ();
        get_style_context ().add_class ("fuzzy-popover");

        var heading = new Granite.HeaderLabel (_("Go to Symbol"));
        if (symbol_index != null) {
            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            header.pack_start (heading, true, true, 0);
            reindex_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic", Gtk.IconSize.BUTTON) {
                tooltip_text = _("Recheck all projects")
            };
            reindex_button.clicked.connect (() => start_global_indexing (true));
            header.pack_end (reindex_button, false, false, 0);
            global_header = header;
        }

        search_entry = new Gtk.SearchEntry () {
            hexpand = true,
            placeholder_text = _("Filter symbols")
        };

        result_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            activate_on_single_click = true
        };
        result_list.set_sort_func (compare_rows);
        result_list.get_style_context ().add_class ("fuzzy-list");

        status_label = new Gtk.Label (_("Reading symbols…")) {
            margin = 18
        };
        status_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        if (symbol_index != null) {
            spinner = new Gtk.Spinner ();
            var status_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
                halign = Gtk.Align.CENTER
            };
            status_box.add (spinner);
            status_box.add (status_label);
            global_status = status_box;
        }

        var scrolled = new Gtk.ScrolledWindow (null, null) {
            propagate_natural_height = true,
            hexpand = true,
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            max_content_height = 400
        };
        scrolled.add (result_list);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        content.add (global_header ?? heading);
        content.add (search_entry);
        content.add (scrolled);
        content.add (global_status ?? status_label);
        content.show_all ();
        add (content);

        search_entry.changed.connect (update_results);
        search_entry.activate.connect (() => {
            var row = result_list.get_selected_row () as SymbolPickerRow;
            if (row == null) {
                row = result_list.get_row_at_index (0) as SymbolPickerRow;
            }

            if (row != null) {
                select_tag (row.tag);
            }
        });

        result_list.row_activated.connect ((row) => {
            var symbol_row = row as SymbolPickerRow;
            if (symbol_row != null) {
                select_tag (symbol_row.tag);
            }
        });
        result_list.move_cursor.connect ((list_box, step, count) => {
            if (step == Gtk.MovementStep.DISPLAY_LINES && count < 0 &&
                list_box.get_focus_child () == list_box.get_row_at_index (0)) {
                search_entry.grab_focus ();
            }
        });

        var key_controller = new Gtk.EventControllerKey (search_entry);
        key_controller.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape) {
                popdown ();
                return Gdk.EVENT_STOP;
            }

            if (keyval == Gdk.Key.Down && result_list.get_row_at_index (0) != null) {
                result_list.get_row_at_index (0).grab_focus ();
                return Gdk.EVENT_STOP;
            }

            return Gdk.EVENT_PROPAGATE;
        });

        map.connect (() => {
            search_entry.grab_focus ();
        });

        destroy.connect (() => {
            is_destroyed = true;
            if (symbol_index != null) {
                if (file_updated_handler != 0) {
                    symbol_index.disconnect (file_updated_handler);
                }
                if (index_state_handler != 0) {
                    symbol_index.disconnect (index_state_handler);
                }
            }
            if (current_subprocess != null) {
                current_subprocess.force_exit ();
            }
            if (results_update_timeout != 0) {
                Source.remove (results_update_timeout);
                results_update_timeout = 0;
            }
            cleanup_temporary_source ();
        });

        if (symbol_index == null) {
            scan_document.begin ();
        } else {
            project_roots = new GLib.Settings ("io.elementary.code.folder-manager").get_strv ("opened-folders");
            tags.add_all (symbol_index.get_cached_tags (project_roots));
            file_updated_handler = symbol_index.file_updated.connect (on_index_file_updated);
            index_state_handler = symbol_index.index_state_changed.connect (on_index_state_changed);
            update_results ();
            if (project_roots.length == 0) {
                status_label.label = _("Open a project to search its symbols");
                status_label.show ();
            } else {
                start_global_indexing (false);
            }
        }
    }

    public Scratch.Services.Document? document {
        get; construct;
    }

    public Scratch.Services.SymbolIndex? symbol_index { get; construct; }
    public Scratch.Widgets.DocumentView? document_view { get; construct; }

    private void start_global_indexing (bool recheck_all) {
        if (symbol_index == null) {
            return;
        }
        status_label.label = recheck_all ? _("Rechecking projects…") : _("Indexing projects; results are partial…");
        symbol_index.start (project_roots, recheck_all);
    }

    private void on_index_file_updated (string path, Gee.ArrayList<SymbolPickerTag> updated_tags) {
        for (var i = tags.size - 1; i >= 0; i--) {
            if (tags[i].path == path) {
                tags.remove_at (i);
            }
        }
        tags.add_all (updated_tags);
        if (!is_destroyed) {
            schedule_results_update ();
        }
    }

    private void schedule_results_update () {
        if (results_update_timeout != 0) {
            return;
        }
        results_update_timeout = Timeout.add (100, () => {
            results_update_timeout = 0;
            if (!is_destroyed) {
                update_results ();
            }
            return Source.REMOVE;
        });
    }

    private void on_index_state_changed (bool active, bool full, int completed, int total) {
        if (is_destroyed) {
            return;
        }
        if (active) {
            is_indexing = true;
            if (reindex_button != null) {
                reindex_button.sensitive = false;
            }
            if (spinner != null) {
                spinner.start ();
            }
            status_label.label = full
                ? _("Indexing projects; results are partial…")
                : _("Updating changed files; results are partial…");
            status_label.show ();
        } else {
            is_indexing = false;
            if (reindex_button != null) {
                reindex_button.sensitive = true;
            }
            if (spinner != null) {
                spinner.stop ();
            }
            status_label.label = tags.size == 0 ? _("No symbols found") : _("%d symbols").printf (tags.size);
            if (tags.size > 0) {
                status_label.hide ();
            } else {
                status_label.show ();
            }
        }
    }

    private async void scan_document () {
        if (document == null) {
            return;
        }
        string source_path;
        try {
            source_path = create_source_snapshot ();
        } catch (Error e) {
            cleanup_temporary_source ();
            status_label.label = _("Could not read symbols from this file");
            warning ("Unable to prepare symbol picker input: %s", e.message);
            return;
        }

        try {
            var flags = GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_SILENCE;
            var language = document.source_view.language;
            if (document.is_file_temporary && language != null && language.id != "txt" && language.id != "def") {
                current_subprocess = new GLib.Subprocess (
                    flags,
                    "ctags", "-f", "-", "--format=2", "--excmd=n", "--fields=nstK", "--extra=", "--sort=no",
                    "--language-force=%s".printf (language.name), source_path
                );
            } else {
                current_subprocess = new GLib.Subprocess (
                    flags,
                    "ctags", "-f", "-", "--format=2", "--excmd=n", "--fields=nstK", "--extra=", "--sort=no",
                    source_path
                );
            }

            read_symbols.begin (current_subprocess, (obj, res) => {
                try {
                    read_symbols.end (res);
                } catch (Error e) {
                    warning ("Unable to read ctags output: %s", e.message);
                }

                cleanup_temporary_source ();
                if (!is_destroyed) {
                    update_results ();
                }
            });
        } catch (Error e) {
            cleanup_temporary_source ();
            status_label.label = _("Could not read symbols from this file");
            warning ("Unable to start ctags for symbol picker: %s", e.message);
        }
    }

    private async void read_symbols (GLib.Subprocess subprocess) throws Error {
        var stream = new GLib.DataInputStream (subprocess.get_stdout_pipe ());
        string? output_line;
        while ((output_line = yield stream.read_line_async ()) != null) {
            var fields = output_line.split ("\t");
            if (fields.length < 5 || !fields[4].has_prefix ("line:")) {
                continue;
            }

            var line = int.parse (fields[4].substring (5));
            if (line < 1) {
                continue;
            }

            var scope = "";
            if (fields.length > 5) {
                var scope_field = fields[5];
                var colon = scope_field.index_of_char (':');
                if (colon >= 0 && colon + 1 < scope_field.length) {
                    scope = scope_field.substring (colon + 1);
                }
            }

            tags.add (new SymbolPickerTag (fields[0], fields[3], scope, line));
        }

        yield subprocess.wait_async ();
    }

    private string create_source_snapshot () throws Error {
        if (document == null) {
            throw new IOError.FAILED (_("This document has no local file"));
        }
        var original_path = document.file.get_path ();
        if (original_path == null) {
            throw new IOError.FAILED (_("This document has no local file"));
        }

        var basename = Path.get_basename (original_path);
        var dot = basename.last_index_of_char ('.');
        var extension = dot > 0 ? basename.substring (dot) : ".txt";
        temporary_directory = DirUtils.make_tmp ("elementary-code-symbol-picker-XXXXXX");
        var source_path = Path.build_filename (temporary_directory, "source" + extension);
        FileUtils.set_contents (source_path, document.get_text ());
        return source_path;
    }

    private void cleanup_temporary_source () {
        if (temporary_directory == "") {
            return;
        }

        var basename = "source";
        if (document == null) {
            temporary_directory = "";
            return;
        }
        var original_path = document.file.get_path ();
        if (original_path != null) {
            var original_basename = Path.get_basename (original_path);
            var dot = original_basename.last_index_of_char ('.');
            if (dot > 0) {
                basename += original_basename.substring (dot);
            } else {
                basename += ".txt";
            }
        } else {
            basename += ".txt";
        }

        FileUtils.remove (Path.build_filename (temporary_directory, basename));
        DirUtils.remove (temporary_directory);
        temporary_directory = "";
    }

    private void update_results () {
        foreach (var child in result_list.get_children ()) {
            result_list.remove (child);
        }

        var query = search_entry.text.strip ().casefold ();
        if (query == "") {
            var visible_tags = int.min (tags.size, 300);
            for (var i = 0; i < visible_tags; i++) {
                result_list.add (new SymbolPickerRow (tags[i], 0));
            }
        } else {
            var matches = new Gee.ArrayList<SymbolPickerMatch> ();
            foreach (var tag in tags) {
                var score = fuzzy_score (query, tag);
                if (score >= 0) {
                    matches.add (new SymbolPickerMatch (tag, score));
                }
            }

            matches.sort (compare_matches);
            var visible_matches = int.min (matches.size, 300);
            for (var i = 0; i < visible_matches; i++) {
                var match = matches[i];
                result_list.add (new SymbolPickerRow (match.tag, match.score));
            }
        }

        var first_row = result_list.get_row_at_index (0);
        if (first_row != null) {
            result_list.select_row (first_row);
            if (!is_indexing) {
                status_label.hide ();
            }
        } else {
            if (!is_indexing) {
                status_label.label = tags.size == 0
                    ? _("No symbols found")
                    : _("No matching symbols");
            }
            status_label.show ();
        }

        result_list.show_all ();
    }

    private int fuzzy_score (string query, SymbolPickerTag tag) {
        var candidate = ("%s %s %s %s".printf (tag.name, tag.scope, tag.kind, tag.path)).casefold ();
        var query_index = 0;
        var candidate_index = 0;
        var previous_match = -2;
        var score = 0;

        while (query_index < query.length && candidate_index < candidate.length) {
            var query_char = query.get_char (query_index);
            var candidate_char = candidate.get_char (candidate_index);
            if (query_char == candidate_char) {
                score += 10;
                if (candidate_index == 0 || candidate.get_char (candidate_index - 1) == ' ' ||
                    candidate.get_char (candidate_index - 1) == '_' ||
                    candidate.get_char (candidate_index - 1) == '-') {
                    score += 12;
                }
                if (candidate_index == previous_match + 1) {
                    score += 8;
                }
                previous_match = candidate_index;
                query_index++;
            }
            candidate_index++;
        }

        return query_index == query.length ? score - candidate.length : -1;
    }

    private int compare_rows (Gtk.ListBoxRow first, Gtk.ListBoxRow second) {
        var first_row = (SymbolPickerRow) first;
        var second_row = (SymbolPickerRow) second;
        if (first_row.score != second_row.score) {
            return second_row.score - first_row.score;
        }
        return first_row.tag.line - second_row.tag.line;
    }

    private int compare_matches (SymbolPickerMatch first, SymbolPickerMatch second) {
        if (first.score != second.score) {
            return second.score - first.score;
        }
        var by_name = strcmp (first.tag.name, second.tag.name);
        if (by_name != 0) {
            return by_name;
        }
        return first.tag.line - second.tag.line;
    }

    private void select_tag (SymbolPickerTag tag) {
        popdown ();
        if (tag.path != "" && document_view != null) {
            document_view.open_document.begin (tag.path, true, -2, SelectionRange.EMPTY, (obj, res) => {
                document_view.open_document.end (res);
                if (document_view.current_document != null) {
                    document_view.current_document.goto (tag.line);
                    document_view.current_document.source_view.grab_focus ();
                }
            });
        } else if (document != null) {
            document.goto (tag.line);
            document.source_view.grab_focus ();
        }
    }
}
