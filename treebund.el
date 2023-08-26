;;; treebund.el --- Bundle related git-worktrees together -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1") (compat "29.1.4.2"))
;; Version: 0.1.0
;; Author: Ben Whitley
;; Homepage: https://github.com/purplg/treebund.el
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; This package is used for bundling related git-worktrees from multiple
;; repositories together.  This helps switch quickly between repositories and
;; ensure you're on the correct branch.  When you're done with your changes, you
;; can use the repositories in the workspace and know which ones were modified
;; to simplify the process of getting the changes merged in together.
;;
;; Additionally, git metadata (the =.git= directory) is shared between all
;; projects.  You can stash, pop, and pull changes in from the same repository in
;; other workspaces thanks to the power of git-worktrees.


;;;; Terminology:

;; Workspace
;;   A collection of 'PROJECT's created from 'BARE's.
;;
;; Project
;;   A git-worktree checked out from a 'BARE' stored in a 'WORKSPACE'.
;;
;; Bare
;;   A bare repository used as a source to create a 'PROJECT's git-worktree.


;;;; Structure:

;; The workspaces directory is structured as such:
;;
;; `treebund-workspace-root' (default: "~/workspaces/")
;;    |
;;    L workspace1
;;    |    L project-one   (branch: "feature/workspace1")
;;    |    L project-two   (branch: "feature/workspace1")
;;    |    L project-three (branch: "feature/workspace1")
;;    |
;;    L workspace2
;;         L project-one   (branch: "feature/workspace2")
;;         L project-two   (branch: "feature/workspace2")
;;         L project-three (branch: "feature/workspace2")


;;;; Quick start:

;; Assuming default configuration, the following will create a bare clone of the
;; provided repo URL to '~/workspaces/.bare/<repo-name>.git', then create and
;; open a worktree for a new branch called 'feature/<workspace-name>'.
;;
;; 1. Interactively call `treebund-add-project'.
;; 2. Enter name for the new (or existing) workspace.
;; 3. Select '[ clone ]'.
;; 4. Enter the URL to clone for the repository to be added to the workspace.


;;;; Configuration:

;; `treebund-prefix'
;;  Default: 'feature/'
;;
;; This is probably the most subjective variable you'd want to customize. With
;; its default value, when you add a project to a workspace named, for example,
;; 'new-protocol', the new project will be checked out to a new branch called
;; 'feature/new-protocol'.

;; `treebund-workspace-root'
;;  Default: '~/workspaces/'
;;
;; This one is also very subjective. It's where all of your workspaces will
;; exist on your file-system.

;; `treebund-project-open-function'
;;  Default: `project-switch-project'
;;
;; This is the function called when a project is opened. You could also just
;; make this `find-file' to just open the file instantly or any other function
;; that takes a file path.

;; `treebund-before-workspace-open-functions'
;; `treebund-before-project-open-functions'
;; `treebund-after-project-open-hook'
;; `treebund-after-workspace-open-hook'
;;
;; These hooks are called before or after a project or workspace is opened. The
;; `-functions'-suffixed hooks take a single argument, which is the path to the
;; project directory or workspace directory to be opened.


;;;; Usage:

;; | Command                     | Description                                 |
;; |-----------------------------+---------------------------------------------|
;; | ~treebund-open~             | Open a project in a workspace               |
;; | ~treebund-open-project~     | Open other project within current workspace |
;; | ~treebund-add-project~      | Add a project to a workspace                |
;; | ~treebund-remove-project~   | Remove a project from a workspace           |
;; | ~treebund-delete-workspace~ | Delete a workspace                          |

;;; Code:
(eval-when-compile (require 'subr-x))
(require 'compat)
(require 'vc-git)


;;;; Customization

(defgroup treebund nil
  "Exploit git-worktrees to create inter-related project workspaces."
  :group 'convenience
  :prefix "treebund-")

(defcustom treebund-prefix "feature/"
  "The string prefix before every new project branch."
  :group 'treebund
  :type 'string)

(defcustom treebund-workspace-root "~/workspaces/"
  "The path where all workspaces are stored."
  :group 'treebund
  :type 'string
  :set (lambda (option value)
         (set option (file-name-as-directory (expand-file-name
                                              value)))))

(defcustom treebund-bare-dir (file-name-concat treebund-workspace-root ".bare")
  "The path where bare repositories are stored."
  :group 'treebund
  :type 'string
  :set (lambda (option value)
         (set option (file-name-as-directory (expand-file-name
                                              value)))))

(defcustom treebund-project-open-function #'project-switch-project
  "Function called to switch to a new project."
  :group 'treebund
  :type 'function)

;; Hooks
(defcustom treebund-before-project-open-functions nil
  "Hook which is run before a project is opened.
A single argument is passed which is the path to the project to
be opened."
  :group 'treebund
  :type '(list function))

(defcustom treebund-after-project-open-hook nil
  "Hook which is run after a project is opened."
  :group 'treebund
  :type 'hook)

(defcustom treebund-before-workspace-open-functions nil
  "Hook which is run before a workspace is opened.
A single argument is passed which is the path to the workspace to
be opened."
  :group 'treebund
  :type '(list function))

(defcustom treebund-after-workspace-open-hook nil
  "Hook which is run after a workspace is opened."
  :group 'treebund
  :type 'hook)


;;;; Logging
(defface treebund--gitlog-heading
  '((t (:inherit mode-line :extend t)))
  "Face for widget group labels in treebund's dashboard."
  :group 'treebund)

(defvar treebund--gitlog-buffer "*treebund-git*")

(defun treebund--gitlog-buffer ()
  "Return the git history log buffer for treebund."
  (or (get-buffer treebund--gitlog-buffer)
      (let ((buf (get-buffer-create treebund--gitlog-buffer)))
        (with-current-buffer buf
          (read-only-mode 1)
          (set (make-local-variable 'window-point-insertion-type) t))
        buf)))

(defun treebund--gitlog (type &rest msg)
  "Insert a message in the treebund git log buffer.
TYPE is the type of log message.  Can be either 'command or 'output.

MSG is the text to be inserted into the log."
  (with-current-buffer (treebund--gitlog-buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (cond ((eq 'command type)
             (insert (propertize (string-join (append '("git") msg '("\n")) " ") 'face 'treebund--gitlog-heading)))
            ((eq 'output type)
             (let ((msg (apply #'format msg)))
               (when (= (length msg) 0)
                 (setq msg " "))
               (insert msg))
             (newline 2))))))

(defun treebund--message (&rest args)
  (message "treebund: %s" (apply #'format args)))

(define-error 'treebund-error "treebund error")

(defun treebund--error (format &rest args)
  "Print and error with ARGS formatted with FORMAT."
  (signal 'treebund-error (list (apply #'format-message format args))))


;;;; Git operations

;; Parse the git output into something more useful.
;;
;; The two macros below should be used only by the functions within this
;; section. Additional git operations should have their own accompanying
;; function instead of using a macro directly.

(defmacro treebund--git (&rest args)
  "Base macro for all treebund git commands.
ARGS are the arguments passed to git."
  (declare (indent defun))
  `(with-temp-buffer
     (treebund--gitlog 'command (string-join (list ,@args) " "))
     (let ((result (vc-git--call t ,@args))
           (output (string-trim-right (buffer-string))))
       (treebund--gitlog 'output output)
       (when (> result 0)
         (user-error "Git command failed with error %s.  See %s" result treebund--gitlog-buffer))
       output)))

(defmacro treebund--git-with-repo (repo-path &rest args)
  "Run a command on a specific git repository.
REPO-PATH is the repository to pass to git with the '-C' switch.

ARGS are the arguments passed to git."
  (declare (indent defun))
  `(treebund--git "-C" ,repo-path ,@args))

(defun treebund--branches (repo-path &optional omit-main)
  "Return a list of branches for repository at REPO-PATH.
When OMIT-MAIN is non-nil, exclude the default branch."
  (let ((branches (split-string (treebund--git-with-repo repo-path
                                  "branch" "--format=%(refname:short)")
                                "\n")))
    (seq-remove #'string-empty-p
                (if omit-main
                    (let ((main-branch (treebund--branch-default repo-path)))
                      (remove main-branch branches))
                  branches))))

(defun treebund--worktree-bare (project-path)
  "Return the bare related to PROJECT-PATH."
  (treebund--git-with-repo project-path
    "rev-parse" "--path-format=absolute" "--git-common-dir"))

(defun treebund--worktree-remove (repo-path)
  "Remove the worktree at REPO-PATH."
  (let ((bare-path (treebund--worktree-bare repo-path)))
    (treebund--git-with-repo bare-path
      "worktree" "remove" repo-path)))

(defun treebund--worktree-add (bare-path worktree-path branch-name)
  "Create a worktree.
BARE-PATH is the main repository the worktree is being created from.

WORKTREE-PATH is the path where the new worktree will be created.

BRANCH-NAME is the name of branch to be created and checked out at PROJECT-PATH.

Returns the path to the newly created worktree."
  (if (member branch-name (treebund--branches bare-path))
      (treebund--git-with-repo bare-path
        "worktree" "add" worktree-path branch-name)
    (treebund--git-with-repo bare-path
      "worktree" "add" worktree-path "-b" branch-name))
  worktree-path)

(defun treebund--worktree-list (repo-path)
  "Return a list of worktrees for REPO-PATH."
  (seq-map
   (lambda (worktree)
     (split-string worktree "\0" t))
   (split-string (treebund--git-with-repo repo-path
                   "worktree" "list" "-z" "--porcelain")
                 "\0\0"
                 t)))

(defun treebund--branch (repo-path)
  "Return the branch checked out REPO-PATH."
  (treebund--git-with-repo repo-path
    "branch" "--show-current"))

(defun treebund--clone (url)
  "Clone a repository from URL to the bare repo directory.
Place the cloned repository as a bare repository in the directory declared in
`treebund-bare-dir' so worktrees can be created from it as workspace projects."
  (let* ((dest (file-name-concat treebund-bare-dir
                                 (car (last (split-string url "/"))))))
    (when (file-exists-p dest)
      (user-error "Repository with this name is already cloned"))
    (treebund--git "clone" url "--bare" dest)
    (treebund--git-with-repo dest "config" "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*")
    (treebund--git-with-repo dest "fetch")
    dest))

(defun treebund--rev-count (repo-path commit-a &optional commit-b)
  "Return the number of commits between COMMIT-A and COMMIT-B at REPO-PATH.
If COMMIT-B is nil, count between HEAD Of default branch and COMMIT-A."
  (unless commit-b
    (setq commit-b commit-a)
    (setq commit-a (treebund--branch-default repo-path)))
  (string-to-number
   (treebund--git-with-repo repo-path
     "rev-list" (concat commit-a ".." commit-b) "--count")))


;;;; Workspace management

;; These functions provide useful functions for and the rules to enforce the
;; definitions of the terminology at the top of this package.

;; Repos
(defmacro treebund--with-repo (repo-path &rest body)
  "Run BODY in the context of a buffer in REPO-PATH.
BODY is evaluated with the context of a buffer in the REPO-PATH repository"
  (declare (indent defun))
  `(let* ((buffer (find-file-noselect ,repo-path))
          (result nil))
     (with-current-buffer buffer
       (setq result ,@body))
     (kill-buffer buffer)
     result))

(defun treebund--repo-worktree-count (repo-path)
  "Return the number of worktrees that exist for REPO-PATH."
  (seq-count
   (lambda (str) (not (member "bare" str)))
   (treebund--worktree-list repo-path)))

(defun treebund--has-worktrees-p (repo-path)
  "Return t if REPO-PATH has any worktrees."
  (> (treebund--repo-worktree-count repo-path) 0))

(defun treebund--unpushed-commits-p (repo-path &optional branches)
  "Return t if there are changes not on remote.
REPO-PATH is the repository to be acted on.

If BRANCH is nil, check all local BRANCHES.  If BRANCH is a string or list of
strings, only check these local branches."
  (when (eq 'string (type-of branches))
    (setq branches (list branches)))
  (setq repo-path (treebund--project-bare repo-path))
  (> (length (treebund--git-with-repo repo-path "log" "--branches" "--not" "--remotes")) 0))

(defun treebund--project-clean-p (project-path)
  "Return t if there are no uncommitted modifications in project.
PROJECT-PATH is the worktree to check."
  (= (length (split-string
              (treebund--git-with-repo project-path
                "status" "-z" "--porcelain")
              "\0"
              t))
     0))

;; Bares
(defun treebund--bare-name (bare-path)
  "Return the name of bare repository at BARE-PATH."
  (when (string-prefix-p treebund-bare-dir bare-path)
    (file-name-base (directory-file-name bare-path))))

(defun treebund--bare-delete (bare-path)
  "Delete the bare repository at BARE-PATH.
This will check to see if BARE-PATH exists within
`treebund-workspace-root' before deleting."
  (setq bare-path (file-name-as-directory bare-path))
  (unless (string-prefix-p treebund-workspace-root bare-path)
    (treebund--error "Bare not within workspace root"))
  (unless (string-suffix-p ".git/" bare-path)
    (treebund--error "Bare repository does not end in .git"))
  (delete-directory bare-path t))

(defun treebund--bare-list ()
  "Return a list of all existing bare repository directory names."
  (directory-files treebund-bare-dir nil "^[^.].*"))

;; Workspaces
(defun treebund--workspace-name (workspace-path)
  "Return the name of a workspace at WORKSPACE-PATH."
  (file-name-nondirectory (directory-file-name workspace-path)))

(defun treebund--workspace-projects (workspace-path)
  "Return a list of absolute paths to projects in WORKSPACE-PATH."
  (seq-filter #'file-directory-p
              (directory-files workspace-path t "^[^.].*")))

(defun treebund--workspaces ()
  "Return a list of all existing workspace names."
  (seq-map #'file-name-nondirectory
           (seq-filter #'file-directory-p
                       (directory-files treebund-workspace-root t "^[^.].*"))))

(defun treebund-current-workspace (&optional file-path)
  "Return the path to the current workspace.
If FILE-PATH is non-nil, use the current buffer instead."
  (when-let ((file-path (or (and file-path (expand-file-name file-path))
                            buffer-file-name)))
    (let ((workspace-name nil))
      ;; Traverse up parent directories until the workspace root is all that remains
      (while (string-prefix-p treebund-workspace-root (directory-file-name file-path))
        (setq workspace-name (file-name-nondirectory (directory-file-name file-path)))
        (setq file-path (file-name-directory (directory-file-name file-path))))
      (when workspace-name
        (file-name-as-directory (file-name-concat treebund-workspace-root workspace-name))))))

;; Projects
(defun treebund--project-add (workspace-path bare-path &optional branch-name project-path)
  "Add a project to a workspace.
Defines the way project worktrees are added and named in workspaces.

WORKSPACE-PATH is the directory to place the new worktree in.

BARE-PATH is the main repository the worktree is being created from.

BRANCH-NAME is the name of branch to be created and checked out in the
workspace.

PROJECT-PATH is the name of the worktrees' directory in the workspace."
  (treebund--worktree-add bare-path
                          (or project-path
                              (file-name-concat workspace-path
                                                (treebund--bare-name bare-path)))
                          (or branch-name
                              (treebund--branch-name workspace-path))))

(defun treebund--project-bare (project-path)
  "Return the respective bare for project at PROJECT-PATH."
  (when-let ((worktrees (seq-find (lambda (worktree) (member "bare" worktree))
                                  (treebund--worktree-list project-path))))
    (cadr (split-string (car worktrees)))))

(defun treebund--project-current (&optional file-path)
  "Return the project path of FILE-PATH.
If FILE-PATH is non-nil, use the current buffer."
  (when-let ((file-path (or (and file-path (expand-file-name file-path))
                            buffer-file-name))
             (workspace-path (treebund-current-workspace file-path)))
    (let ((project-name nil))
      ;; Traverse up parent directories until the current workspace is all that remains
      (while (string-prefix-p workspace-path (directory-file-name file-path))
        (setq project-name (file-name-nondirectory (directory-file-name file-path)))
        (setq file-path (file-name-directory (directory-file-name file-path))))
      (when project-name
        (file-name-concat workspace-path project-name)))))

(defun treebund--project-name (file-path)
  "Return the name of project at FILE-PATH."
  (when-let ((project-path (treebund--project-current file-path)))
    (file-name-nondirectory (directory-file-name file-path))))

;; Branches
(defun treebund--branch-name (workspace-path)
  "Generate a branch name for WORKSPACE-PATH."
  (concat treebund-prefix (treebund--workspace-name workspace-path)))

(defun treebund--branch-default (repo-path)
  "Return the default branch at REPO-PATH."
  (treebund--with-repo repo-path
    (car (vc-git-branches))))


;;;; User functions

;; This section provides the stable user interface.

(defun treebund--read-bare (&optional prompt clone omit)
  "Interactively find the path of a bare.
PROMPT is the text prompt presented to the user in the minibuffer.

When CLONE is non-nil, add a completion candidate named this
'[ clone ]' which will prompt the user to clone a new repository
instead.

When OMIT is non-nil, it should be a list of a candidates to be
excluded from the candidates."
  (let* ((candidates (mapcar (lambda (bare)
                               (cons (replace-regexp-in-string "\.git$" "" bare)
                                     (file-name-concat treebund-bare-dir bare)))
                             (treebund--bare-list))))
    (when omit
      (setq candidates (seq-remove (lambda (bare) (member (car bare) omit))
                                   candidates)))
    (when clone
      (setq candidates (append candidates '(("[ clone ]" . clone)))))
    (if-let ((selection (cdr (assoc (completing-read (or prompt "Select project: ") candidates) candidates))))
        (if (equal selection 'clone)
            (call-interactively #'treebund-clone)
          selection))))

(defun treebund--read-project (workspace-path &optional prompt add initial)
  "Interactively find the path of a project.
WORKSPACE-PATH is the workspace to look for projects in.

PROMPT is the prompt to be presented to the user in the
minibuffer.

When ADD is non-nil, add an option for the user to add a project
that isn't in the workspace.

INITIAL is the default value for the name of the project that is automatically
inserted when the minibuffer is shown."
  (let* ((candidates (mapcar (lambda (project)
                               (cons (file-name-nondirectory project) project))
                             (treebund--workspace-projects workspace-path))))
    (when add (setq candidates (append candidates '(("[ add ]" . add)))))
    (let* ((selection (completing-read (or prompt "Project: ") candidates nil nil initial))
           (value (cdr (assoc selection candidates))))
      (if (equal value 'add)
          (let ((bare-path (treebund--read-bare prompt t)))
            (treebund--project-add workspace-path
                                   bare-path
                                   (treebund--branch-name workspace-path)))
        (expand-file-name selection workspace-path)))))

(defun treebund--read-workspace (&optional prompt require-match)
  "Interactively find the path of a workspace.
PROMPT is the prompt to be presented to the user in the
minibuffer.

REQUIRE-MATCH forces a valid workspace to be selected.  This removes the ability
to create a workspace with a new entry."
  (let* ((candidates (mapcar (lambda (workspace)
                               (cons workspace
                                     (expand-file-name workspace treebund-workspace-root)))
                             (treebund--workspaces)))
         (default (when-let ((workspace-path (treebund-current-workspace)))
                    (treebund--workspace-name workspace-path)))
         (prompt (if default (format "%s [%s]: " (or prompt "Workspace") default) "Workspace: "))
         (selection (completing-read prompt candidates nil require-match nil nil default)))
    (if-let ((existing (cdr (assoc selection candidates))))
        existing
      (let ((workspace-path (file-name-concat treebund-workspace-root selection)))
        (make-directory workspace-path)
        workspace-path))))

(defun treebund--git-url-like-p (url)
  "Return non-nil if URL seems like a git-clonable URL.
The URL is returned for non-nil."
  (and (or (string-prefix-p "ssh://git@" url)
           (string-prefix-p "git@" url)
           (string-prefix-p "http://" url)
           (string-prefix-p "https://" url))
       (string-suffix-p ".git" url)
       url))

(defun treebund--open (project-path)
  "Open a project in some treebund workspace.
PROJECT-PATH is the project to be opened."
  (let* ((workspace-path (treebund-current-workspace project-path))
         (new-workspace-p (not (string= (treebund-current-workspace) workspace-path)))
         (new-project-p (not (string= (treebund--project-current) project-path))))
    (when new-workspace-p (run-hook-with-args 'treebund-before-workspace-open-functions workspace-path))
    (when new-project-p (run-hook-with-args 'treebund-before-project-open-functions project-path))

    (funcall treebund-project-open-function project-path)

    (when new-project-p (run-hooks 'treebund-after-project-open-hook))
    (when new-workspace-p (run-hooks 'treebund-after-workspace-open-hook))))

;;;###autoload
(defun treebund-open (workspace-path)
  "Open or create a workspace and a project within it.

WORKSPACE-PATH is the workspace to open.

This will always prompt for a workspace.  If you want to prefer your current
workspace, use `treebund-open-project'."
  (interactive (list (treebund--read-workspace "Open workspace")))
  (treebund--open
   (treebund--read-project workspace-path
                           (format "Open project in %s: " (treebund--workspace-name workspace-path))
                           t)))

;;;###autoload
(defun treebund-open-project ()
  "Open a project in some treebund workspace.
This function will try to use your current workspace first if the
current buffer is in one."
  (interactive)
  (treebund-open
   (or (treebund-current-workspace)
       (treebund--read-workspace))))

;;;###autoload
(defun treebund-delete-workspace (workspace-path)
  "Delete workspace at WORKSPACE-PATH.
This will check if all projects within the workspace are clean and if so, remove
everything in the workspace. Anything committed is still saved in the respective
projects' bare repository located at `treebund-bare-dir'."
  (interactive
   (list (treebund--read-workspace "Delete workspace" t)))
  (let ((project-paths (directory-files workspace-path t "^[^.].*")))
    (if (and (f-directory-p workspace-path)
             (seq-every-p (lambda (project-path)
                            (treebund--project-clean-p project-path))
                          project-paths))
        (progn
          (dolist (project-path project-paths)
            (treebund--worktree-remove project-path))
          (delete-directory workspace-path)
          (treebund--message "Deleted workspace `%s'" (treebund--workspace-name workspace-path)))
      (user-error "There must not be any unsaved changes to delete a workspace"))))

;;;###autoload
(defun treebund-add-project (workspace-path bare-path project-path project-branch)
  "Add a project to a workspace.
This will create a worktree in WORKSPACE-PATH with a branch named
after the workspace with `treebund-prefix' prefixed.

WORKSPACE-PATH is the path to the workspace in which the worktree
will be created.

BARE-PATH is the bare git repository where the worktree is
derived.

PROJECT-PATH is the path where the worktree will be created.  The
provided path should be in WORKSPACE-PATH directory.

PROJECT-BRANCH is the name of the branch to be checked out for
this project."
  (interactive
   (let* ((workspace-path (treebund--read-workspace "Add project to"))
          (bare-path (treebund--read-bare (format "Add project to %s: "
                                                  (treebund--workspace-name workspace-path))
                                          t
                                          (treebund--workspace-projects workspace-path)))
          (project-branch (completing-read "Branch: "
                                           (treebund--branches bare-path)
                                           nil
                                           nil
                                           (treebund--branch-name workspace-path)))
          (project-path (treebund--read-project workspace-path "Project name: "
                                                nil
                                                (treebund--bare-name bare-path))))
     (list workspace-path bare-path project-path project-branch)))
  (treebund--open (treebund--project-add workspace-path
                                         bare-path
                                         project-branch
                                         project-path)))

;;;###autoload
(defun treebund-remove-project (project-path)
  "Remove project at PROJECT-PATH from a workspace.
There must be no changes in the project to remove it."
  (interactive
   (let ((workspace-path (or (and (not current-prefix-arg)
                                  (treebund-current-workspace))
                             (treebund--read-workspace "Remove project from" t))))
     (list (treebund--read-project workspace-path
                                   (format "Remove project from %s: "
                                           (treebund--workspace-name workspace-path))))))
  (if (treebund--project-clean-p project-path)
      (progn
        (treebund--worktree-remove project-path)
        (treebund--message "Removed project `%s'" (treebund--project-name project-path)))
    (treebund--error "Cannot remove '%s/%s' because the project is dirty"
                     (treebund--workspace-name (treebund-current-workspace project-path))
                     (treebund--project-name project-path))))

;;;###autoload
(defun treebund-clone (url)
  "Clone URL to the collection of bare repos.
Once a repository is in the bare repos collection, you can add it to a project
with `treebund-add-project'"
  (interactive
   (list (read-string "URL: " (or (treebund--git-url-like-p (gui-get-selection 'CLIPBOARD 'STRING))
                                  (treebund--git-url-like-p (gui-get-selection 'PRIMARY 'STRING))))))
  (treebund--message "Cloning %s..." url)
  (let ((bare-path (treebund--clone url)))
    (treebund-message "Finished cloning %s." (treebund--bare-name bare-path))
    bare-path))

;;;###autoload
(defun treebund-delete-bare (bare-path &optional interactive)
  "Delete a bare repository at BARE-PATH.
Existing worktrees or uncommitted changes will prevent you from deleting.

If INTERACTIVE is non-nil, prompt the user to force delete for any changes not
on remote."
  (interactive
   (list (treebund--read-bare "Select repo to delete: ") t))
  (cond ((treebund--has-worktrees-p bare-path)
         (treebund--error "This repository has worktrees checked out"))
        ((and (treebund--unpushed-commits-p bare-path)
              (not (if interactive
                       (yes-or-no-p (format "%s has unpushed commits on some branches.  Delete anyway?" (treebund--bare-name bare-path)))
                     (treebund--error (format "%s has unpushed commits on some branches" (treebund--bare-name bare-path)))))))
        (t (treebund--bare-delete bare-path))))

(provide 'treebund)

;;; treebund.el ends here
