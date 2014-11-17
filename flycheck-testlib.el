;;; flycheck-testlib.el --- Flycheck: Unit test library  -*- lexical-binding: t; -*-

;; Copyright (C) 2014  Sebastian Wiesner

;; Author: Sebastian Wiesner <swiesner@lunaryorn.com>
;; Keywords:

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Unit testing library for Flycheck, the modern on-the-fly syntax checking
;; extension for GNU Emacs.

;; Provide various utility functions and unit test helpers to test Flycheck and
;; Flycheck extensions.

;;; Code:

(require 'flycheck)
(require 'ert)


;;; Compatibility

(eval-and-compile
  ;; Provide `ert-skip' and friends for Emacs 24.3
  (defconst flycheck-test-ert-can-skip (fboundp 'ert-skip)
    "Whether ERT supports test skipping.")

  (unless flycheck-test-ert-can-skip
    ;; Fake skipping

    (put 'flycheck-test-skipped 'error-message "Test skipped")
    (put 'flycheck-test-skipped 'error-conditions '(error))

    (defun ert-skip (data)
      (signal 'flycheck-test-skipped data))

    (defmacro skip-unless (form)
      `(unless (ignore-errors ,form)
         (signal 'flycheck-test-skipped ',form)))

    (defun ert-test-skipped-p (result)
      (and (ert-test-failed-p result)
           (eq (car (ert-test-failed-condition result))
               'flycheck-test-skipped)))))


;;; Internal variables

(defvar flycheck-test--resource-directory nil
  "The directory to get resources from in this test suite.")


;;; Resource management macros

(defmacro flycheck-test-with-temp-buffer (&rest body)
  "Eval BODY within a temporary buffer.

Like `with-temp-buffer', but resets the modification state of the
temporary buffer to make sure that it is properly killed even if
it has a backing file and is modified."
  (declare (indent 0))
  `(with-temp-buffer
     (unwind-protect
         ,(macroexp-progn body)
       ;; Reset modification state of the buffer, and unlink it from its backing
       ;; file, if any, because Emacs refuses to kill modified buffers with
       ;; backing files, even if they are temporary.
       (set-buffer-modified-p nil)
       (set-visited-file-name nil 'no-query))))

(defmacro flycheck-test-with-file-buffer (file-name &rest body)
  "Create a buffer from FILE-NAME and eval BODY.

BODY is evaluated with `current-buffer' being a buffer with the
contents FILE-NAME."
  (declare (indent 1))
  `(let ((file-name ,file-name))
     (unless (file-exists-p file-name)
       (error "%s does not exist" file-name))
     (flycheck-test-with-temp-buffer
       (insert-file-contents file-name 'visit)
       (set-visited-file-name file-name 'no-query)
       (cd (file-name-directory file-name))
       ;; Mark the buffer as not modified, because we just loaded the file up to
       ;; now.
       (set-buffer-modified-p nil)
       ,@body)))

(defmacro flycheck-test-with-help-buffer (&rest body)
  "Execute BODY and kill the help buffer afterwards.

Use this macro to test functions that create a Help buffer."
  (declare (indent 0))
  `(unwind-protect
       ,(macroexp-progn body)
     (when (buffer-live-p (get-buffer (help-buffer)))
       (kill-buffer (help-buffer)))))

(defmacro flycheck-test-with-global-mode (&rest body)
  "Execute BODY with Global Flycheck Mode enabled.

After BODY, disable Global Flycheck Mode again."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (global-flycheck-mode 1)
         ,@body)
     (global-flycheck-mode -1)))

(defmacro flycheck-test-with-env (env &rest body)
  "Add ENV to `process-environment' in BODY.

Execute BODY with a `process-environment' with contains all
variables from ENV added.

ENV is an alist, where each cons cell `(VAR . VALUE)' is a
environment variable VAR to be added to `process-environment'
with VALUE."
  (declare (indent 1))
  `(let ((process-environment (copy-sequence process-environment)))
     (pcase-dolist (`(,var . ,value) ,env)
       (setenv var value))
     ,@body))


;;; Test resources
(defun flycheck-test-resource-filename (resource-file)
  "Determine the absolute file name of a RESOURCE-FILE.

Relative file names are expanded against
`flycheck-test-resources-directory'."
  (expand-file-name resource-file flycheck-test--resource-directory))

(defmacro flycheck-test-with-resource-buffer (resource-file &rest body)
  "Create a temp buffer from a RESOURCE-FILE and execute BODY.

The absolute file name of RESOURCE-FILE is determined with
`flycheck-test-resource-filename'."
  (declare (indent 1))
  `(flycheck-test-with-file-buffer
       (flycheck-test-resource-filename ,resource-file)
     ,@body))

(defun flycheck-test-locate-config-file (filename _checker)
  "Find a configuration FILENAME within unit tests.

_CHECKER is ignored."
  (let* ((directory (flycheck-test-resource-filename "config-files"))
         (filepath (expand-file-name filename directory)))
    (when (file-exists-p filepath)
      filepath)))


;;; Test suite initialization

(defun flycheck-test-initialize (resource-dir)
  "Initialize a test suite with RESOURCE-DIR.

RESOURCE-DIR is a directory to get resource files from in
`flycheck-test-resource-filename'."
  (when flycheck-test--resource-directory
    (error "Test suite already initialized"))
  (let ((tests (ert-select-tests t t)))
    ;; Select all tests
    (unless tests
      (error "No tests defined.  Call `flycheck-test-initialize' after defining all tests!"))

    (setq flycheck-test--resource-directory resource-dir)

    ;; Emacs 24.3 don't support skipped tests, so we add poor man's test
    ;; skipping: We mark skipped tests as expected failures by adjusting the
    ;; expected result of all test cases. Not particularly pretty, but works :)
    (unless flycheck-test-ert-can-skip
      (dolist (test tests)
        (let ((result (ert-test-expected-result-type test)))
          (setf (ert-test-expected-result-type test)
                `(or ,result (satisfies ert-test-skipped-p))))))))


;;; Environment and version information

(defconst flycheck-test-user-error-type
  (if (version< emacs-version "24.2")
      'error
    'user-error)
  "The `user-error' type used by Flycheck.")

(defun flycheck-test-travis-ci-p ()
  "Determine whether we are running on Travis CI."
  (string= (getenv "TRAVIS") "true"))

(defun flycheck-test-check-gpg ()
  "Check whether GPG is available."
  (or (epg-check-configuration (epg-configuration)) t))

(defun flycheck-test-extract-version-command (re executable &rest args)
  "Use RE to extract the version from EXECUTABLE with ARGS.

Run EXECUTABLE with ARGS, catch the output, and apply RE to find
the version number.  Return the text captured by the first group
in RE, or nil, if EXECUTABLE is missing, or if RE failed to
match."
  (-when-let (executable (executable-find executable))
    (with-temp-buffer
      (apply #'call-process executable nil t nil args)
      (goto-char (point-min))
      (when (re-search-forward re nil 'no-error)
        (match-string 1)))))


;;; Test case definitions
(defmacro flycheck-test-def-checker-test (checker language name
                                                  &rest keys-and-body)
  "Define a test case for a syntax CHECKER for LANGUAGE.

CHECKER is a symbol or a list of symbols denoting syntax checkers
being tested by the test.  The test case is skipped, if any of
these checkers cannot be used.  LANGUAGE is a symbol or a list of
symbols denoting the programming languages supported by the
syntax checkers.  This is currently only used for tagging the
test appropriately.

NAME is a symbol denoting the local name of the test.  The test
itself is ultimately named
`flycheck-define-checker/CHECKER/NAME'.  If CHECKER is a list,
the first checker in the list is used for naming the test."
  (declare (indent 3))
  (unless checker
    (error "No syntax checkers specified."))
  (unless language
    (error "No languages specified"))
  (let* ((checkers (if (symbolp checker) (list checker) checker))
         (checker (car checkers))
         (languages (if (symbolp language) (list language) language))
         (language-tags (mapcar (lambda (l) (intern (format "language-%s" l)))
                                languages))
         (local-name (or name 'default))
         (full-name (intern (format "flycheck-define-checker/%s/%s"
                                    checker local-name)))
         (keys-and-body (ert--parse-keys-and-body keys-and-body))
         (body (cadr keys-and-body))
         (keys (car keys-and-body))
         (tags (append '(syntax-checker external-tool)
                       language-tags
                       (plist-get keys :tags))))
    `(ert-deftest ,full-name ()
       :expected-result
       (list 'or
             '(satisfies flycheck-test-syntax-check-timed-out-p)
             ,(or (plist-get keys :expected-result) :passed))
       :tags ',tags
       ,@(mapcar (lambda (c) `(skip-unless (flycheck-check-executable ',c)))
                 checkers)
       ,@body)))


;;; Test case results

(defun flycheck-test-syntax-check-timed-out-p (result)
  "Whether RESULT denotes a timed-out test."
  (and (ert-test-failed-p result)
       (eq (car (ert-test-failed-condition result))
           'flycheck-test-syntax-check-timed-out)))


;;; Syntax checking in tests

(defvar-local flycheck-test-syntax-checker-finished nil
  "Non-nil if the current checker has finished.")

(add-hook 'flycheck-after-syntax-check-hook
          (lambda () (setq flycheck-test-syntax-checker-finished t)))

(defconst flycheck-test-checker-wait-time 10
  "Time to wait until a checker is finished in seconds.

After this time has elapsed, the checker is considered to have
failed, and the test aborted with failure.")

(put 'flycheck-test-syntax-check-timed-out 'error-message
     "Syntax check timed out.")
(put 'flycheck-test-syntax-check-timed-out 'error-conditions '(error))

(defun flycheck-test-wait-for-syntax-checker ()
  "Wait until the syntax check in the current buffer is finished."
  (let ((starttime (float-time)))
    (while (and (not flycheck-test-syntax-checker-finished)
                (< (- (float-time) starttime) flycheck-test-checker-wait-time))
      (sleep-for 1))
    (unless (< (- (float-time) starttime) flycheck-test-checker-wait-time)
      (flycheck-stop-checker)
      (signal 'flycheck-test-syntax-check-timed-out nil)))
  (setq flycheck-test-syntax-checker-finished nil))

(defun flycheck-test-buffer-sync ()
  "Check the current buffer synchronously."
  (setq flycheck-test-syntax-checker-finished nil)
  (should (not (flycheck-running-p)))
  (flycheck-mode)                       ; This will only start a deferred check,
  (flycheck-buffer)                     ; so we need an explicit manual check
  ;; After starting the check, the checker should either be running now, or
  ;; already be finished (if it was fast).
  (should (or flycheck-current-process
              flycheck-test-syntax-checker-finished))
  ;; Also there should be no deferred check pending anymore
  (should-not (flycheck-deferred-check-p))
  (flycheck-test-wait-for-syntax-checker))

(defun flycheck-test-ensure-clear ()
  "Clear the current buffer.

Raise an assertion error if the buffer is not clear afterwards."
  (flycheck-clear)
  (should (not flycheck-current-errors))
  (should (not (-any? (lambda (ov) (overlay-get ov 'flycheck-overlay))
                      (overlays-in (point-min) (point-max))))))


;;; Test assertions

(defun flycheck-test-should-overlay (error)
  "Test that ERROR has an overlay."
  (let* ((overlay (-first (lambda (ov) (equal (overlay-get ov 'flycheck-error)
                                              error))
                          (flycheck-overlays-in 0 (+ 1 (buffer-size)))))
         (region (flycheck-error-region-for-mode error 'symbols))
         (message (flycheck-error-message error))
         (level (flycheck-error-level error))
         (category (flycheck-error-level-overlay-category level))
         (face (get category 'face))
         (fringe-bitmap (flycheck-error-level-fringe-bitmap level))
         (fringe-face (flycheck-error-level-fringe-face level))
         (fringe-icon (list 'left-fringe fringe-bitmap fringe-face)))
    (should overlay)
    (should (overlay-get overlay 'flycheck-overlay))
    (should (= (overlay-start overlay) (car region)))
    (should (= (overlay-end overlay) (cdr region)))
    (should (eq (overlay-get overlay 'face) face))
    (should (equal (get-char-property 0 'display
                                      (overlay-get overlay 'before-string))
                   fringe-icon))
    (should (eq (overlay-get overlay 'category) category))
    (should (equal (overlay-get overlay 'flycheck-error) error))
    (should (string= (overlay-get overlay 'help-echo) message))))

(defun flycheck-test-should-errors (&rest errors)
  "Test that the current buffers has ERRORS.

Without ERRORS test that there are any errors in the current
buffer.

With ERRORS, test that each error in ERRORS is present in the
current buffer, and that the number of errors in the current
buffer is equal to the number of given ERRORS.

Each error in ERRORS is a list as expected by
`flycheck-test-should-error'."
  (if (not errors)
      (should flycheck-current-errors)
    (let ((expected (mapcar (apply-partially #'apply #'flycheck-error-new-at)
                            errors)))
      (should (equal expected flycheck-current-errors))
      (mapc #'flycheck-test-should-overlay expected))
    (should (= (length errors)
               (length (flycheck-overlays-in (point-min) (point-max)))))))

(defun flycheck-test-should-syntax-check (resource-file modes &rest errors)
  "Test a syntax check in RESOURCE-FILE with MODES.

RESOURCE-FILE is the file to check.  MODES is a single major mode
symbol or a list thereof, specifying the major modes to syntax
check with.  ERRORS is the list of expected errors.  If omitted,
the syntax check must not emit any errors.

The syntax checker is selected via standard syntax checker
selection.  To test a specific checker, you need to set
`flycheck-checker' or `flycheck-disabled-checkers' accordingly
before using this predicate, depending on whether you want to use
manual or automatic checker selection.

During the syntax check, configuration files of syntax checkers
are also searched in the `config-files' sub-directory of the
resource directory."
  (when (symbolp modes)
    (setq modes (list modes)))
  (dolist (mode modes)
    (unless (fboundp mode)
      (ert-skip (format "%S missing" mode)))
    (flycheck-test-with-resource-buffer resource-file
      (funcall mode)
      ;; Configure config file locating for unit tests
      (dolist (fn '(flycheck-locate-config-file-absolute-path
                    flycheck-test-locate-config-file))
        (add-hook 'flycheck-locate-config-file-functions fn 'append 'local))
      (let ((process-hook-called 0))
        (add-hook 'flycheck-process-error-functions
                  (lambda (_err)
                    (setq process-hook-called (1+ process-hook-called))
                    nil)
                  nil :local)
        (flycheck-test-buffer-sync)
        (if errors
            (apply #'flycheck-test-should-errors errors)
          (should-not flycheck-current-errors))
        (should (= process-hook-called (length errors))))
      (flycheck-test-ensure-clear))))

(defun flycheck-test-at-nth-error (n)
  (let* ((error (nth (1- n) flycheck-current-errors))
         (mode flycheck-highlighting-mode)
         (region (flycheck-error-region-for-mode error mode)))
    (and (member error (flycheck-overlay-errors-at (point)))
         (= (point) (car region)))))

(defun flycheck-test-explain--at-nth-error (n)
  (let ((errors (flycheck-overlay-errors-at (point))))
    (if (null errors)
        (format "Expected to be at error %s, but no error at point %s"
                n (point))
      (let ((pos (cl-position (car errors) flycheck-current-errors)))
        (format "Expected to be at error %s, but point %s is at error %s"
                n (point) (1+ pos))))))

(put 'flycheck-test-at-nth-error 'ert-explainer
     'flycheck-test-explain--at-nth-error)

(provide 'flycheck-testlib)

;;; flycheck-testlib.el ends here
