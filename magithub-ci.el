;;; magithub-ci.el --- Show CI status as a magit-status header  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; Keywords: tools

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

;; Provide the CI status of "origin" in the Magit status buffer.

;;; Code:

(require 'magit)
(require 'magit-section)
(require 'magit-popup)

(require 'magithub-core)
(require 'magithub-cache)

(defconst magithub-ci-status-symbol-alist
  '(("✔" . success)
    ("✖" . failure)                     ; also means `error'... gross
    ("●" . pending))
  "Because hub 2.3 is silly and does silly things.
Reference: https://github.com/github/hub/blob/master/commands/ci_status.go#L107")

(defconst magithub-ci-status-regex
  (rx bos
      (group any) (* any) "\t"
      (group (* any)) "\t"
      (? (group (* any))) eos))

(defvar magithub-ci-urls nil
  "An alist mapping of repositories to CI urls.")

(defun magithub-ci-enabled-p ()
  "Non-nil if CI is enabled for this repository.
If magithub.ci.enabled is not set, CI is considered to be enabled."
  (when (member (magit-get "magithub" "ci" "enabled") '(nil "yes")) t))
(defun magithub-ci-disable ()
  "Disable CI for this repository."
  (magit-set "no" "magithub" "ci" "enabled"))
(defun magithub-ci-enable ()
  "Enable CI for this repository."
  (magit-set "yes" "magithub" "ci" "enabled"))

(defun magithub-maybe-insert-ci-status-header ()
  "If this is a GitHub repository, insert the CI status header."
  (when (and (magithub-ci-enabled-p)
             (magithub-usable-p))
    (magithub-insert-ci-status-header)))

(defun magithub-ci-toggle ()
  "Toggle CI integration."
  (interactive)
  (if (magithub-ci-enabled-p)
      (magithub-ci-disable)
    (magithub-ci-enable))
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(magit-define-popup-action 'magithub-dispatch-popup
  ?~ "Toggle CI for this repository" #'magithub-ci-toggle ?`)

(defun magithub-ci-status ()
  "One of 'success, 'error, 'failure, 'pending, or 'no-status."
  (let ((same-commit
         (string-equal (magit-rev-parse "HEAD")
                       (magithub-ci-status-current-commit))))
    (unless same-commit
      (magithub-cache-clear (magithub-repo-id) :ci-status))
    (if (eq (magithub-cache-value (magithub-repo-id) :ci-status)
            'success)
        'success
      (magithub-cache (magithub-repo-id) :ci-status
        '(magithub-ci-status--internal)))))

(defun magithub-ci-status-current-commit (&optional new-value)
  "The commit our cached value corresponds to."
  (let ((keys (list "magithub" "ci" "lastCommit")))
    (if new-value (apply #'magit-set new-value keys)
      (apply #'magit-get keys))))

(defun magithub-ci-update-urls (statuses)
  "Updates `magithub-ci-urls' according to STATUSES.
See also `magithub-repo-id'."
  (setcdr (assoc (magithub-repo-id) magithub-ci-urls)
          (mapcar (lambda (s) (plist-get s :url)) statuses)))

(defun magithub-ci-status--parse-2.2.8 (output)
  "Backwards compatibility for old versions of hub.
See `magithub-ci-status--parse'."
  (let ((matches (cdr (s-match (rx bos (group (+ (any alpha space)))
                                   (? ": " (group (+ (not (any " "))))) eos)
                               output)))
        status)
    (when matches
      (setq status (list :status (intern (replace-regexp-in-string "\s" "-" (car matches)))
                         :url (cadr matches)))
      (prog1 status
        (magithub-ci-update-urls (list status))))))

(defun magithub-ci-status--internal (&optional for-commit)
  "One of 'success, 'error, 'failure, 'pending, or 'no-status."
  (let* ((current-commit (magit-rev-parse "HEAD"))
         (last-commit (or for-commit current-commit))
         (output (magithub--command-output "ci-status" `("-v" ,last-commit)))
         (parsed (if (magithub-hub-version-at-least "2.3")
                     (car (magithub-ci-status--parse output))
                   (magithub-ci-status--parse-2.2.8 (car output)))))
    (if parsed
        (prog1 (or (plist-get parsed :status) 'no-status)
          (if (not (or for-commit (plist-get parsed :status)))
              (let ((last-commit (magithub-ci-status--last-commit)))
                (unless (string-equal current-commit last-commit)
                  (magithub-ci-status--internal last-commit))
                (magithub-ci-status-current-commit current-commit))
            (magithub-ci-status-current-commit current-commit)))
      (beep)
      (setq magithub-hub-error
            (message
             (concat "Hub didn't have any recognizable output for \"ci-status\"!\n"
                     "Are you connected to the internet?\n"
                     "Consider submitting an issue to github/hub.")))
      'internal-error)))

(defun magithub-ci-status--parse (output)
  "Parse a string OUTPUT into a list of statuses.
The first status will be an `overall' status."
  (let ((statuses (mapcar #'magithub-ci-status--parse-line output))
        (get-status (lambda (status) (lambda (s) (eq (plist-get s :status) status)))))
    (magithub-ci-update-urls statuses)
    (cons
     (list :check 'overall
           :status
           (cond
            ((-all? (funcall get-status 'success) statuses) 'success)
            ((-some? (funcall get-status 'pending) statuses) 'pending)
            ((-some? (funcall get-status 'error) statuses) 'error)
            ((-some? (funcall get-status 'failure) statuses) 'failure)))
     statuses)))

(defun magithub-ci-status--parse-line (line)
  "Parse a single LINE of status into a status plist."
  (let ((status (cdr (s-match magithub-ci-status-regex line))))
    (if status
        (list :status (cdr (assoc (car status) magithub-ci-status-symbol-alist))
              :url (car (cddr status))
              :check (cadr status))
      (if (string= line "no-status")
          'no-status
        (if (string= line "") 'no-output)))))

(defun magithub-ci-status--last-commit ()
  "Find the commit considered to have the current CI status.
Right now, this finds the most recent commit without

    [ci skip]

or

    [skip ci]

in the commit message.

See the following resources:

 - https://docs.travis-ci.com/user/customizing-the-build#Skipping-a-build
 - https://circleci.com/docs/skip-a-build/"
  (let* ((args '("--invert-grep"
                 "--grep=\\[ci skip\\]"
                 "--grep=\\[skip ci\\]"
                 "--format=oneline"
                 "--max-count=1"))
         (output (magit-git-lines "log" args)))
    (car (split-string (car output)))))

(defvar magithub-ci-status-alist
  '((no-status . "None")
    (error . "Error")
    (internal-error . magithub-ci--hub-error-string)
    (failure . "Failure")
    (pending . "Pending")
    (success . "Success")))

(defun magithub-ci--hub-error-string ()
  "Internal error string."
  (format "Internal error!\n%s" magithub-hub-error))

(defface magithub-ci-no-status
  '((((class color)) :inherit magit-dimmed))
  "Face used when CI status is `no-status'."
  :group 'magithub-faces)

(defface magithub-ci-error
  '((((class color)) :inherit magit-signature-untrusted))
  "Face used when CI status is `error'."
  :group 'magithub-faces)

(defface magithub-ci-pending
  '((((class color)) :inherit magit-signature-untrusted))
  "Face used when CI status is `pending'."
  :group 'magithub-faces)

(defface magithub-ci-success
  '((((class color)) :inherit magit-signature-good))
  "Face used when CI status is `success'."
  :group 'magithub-faces)

(defface magithub-ci-failure
  '((((class color)) :inherit magit-signature-bad))
  "Face used when CI status is `'"
  :group 'magithub-faces)

(defface magithub-ci-unknown
  '((((class color)) :inherit magit-signature-untrusted))
  "Face used when CI status is `unknown'."
  :group 'magithub-faces)

(defun magithub-ci-visit ()
  "Browse the CI.
Sets up magithub.ci.url if necessary."
  (interactive)
  (let* ((urls (cdr (assoc (magithub-repo-id) magithub-ci-urls)))
         (target-url (if (= 1 (length urls)) (car urls)
                       (when urls (completing-read "CI Dashboard URL: " urls)))))
    (when (or (null target-url) (string= "" target-url))
      (user-error "No CI URL detected"))
    (browse-url target-url)))

(defvar magit-magithub-ci-status-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit-visit-thing] #'magithub-ci-visit)
    (define-key map [remap magit-refresh] #'magithub-ci-refresh)
    map)
  "Keymap for `magithub-ci-status' header section.")

(defun magithub-ci-refresh ()
  "Invalidate the CI cache and refresh the buffer."
  (interactive)
  (magithub-cache-clear (magithub-repo-id) :ci-status)
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(defun magithub-insert-ci-status-header ()
  (let* ((status (magithub-ci-status))
         (face   (intern (format "magithub-ci-%s"
                                 (symbol-name status))))
         (status-val (cdr (assq status magithub-ci-status-alist))))
    (magit-insert-section (magithub-ci-status)
      (insert (format "%-10s" "CI: "))
      (insert (propertize
               (cond
                ((stringp status-val) status-val)
                ((functionp status-val) (funcall status-val))
                (t (format "%S" status-val)))
               'face (if (facep face) face 'magithub-ci-unknown)))
      (insert ?\n))))

(defun magithub-toggle-ci-status-header ()
  (interactive)
  (if (memq #'magithub-maybe-insert-ci-status-header magit-status-headers-hook)
      (remove-hook 'magit-status-headers-hook #'magithub-maybe-insert-ci-status-header)
    (if (executable-find magithub-hub-executable)
        (add-hook 'magit-status-headers-hook #'magithub-maybe-insert-ci-status-header t)
      (message "Magithub: (magithub-toggle-ci-status-header) `hub' isn't installed, so I can't insert the CI header")))
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(magithub-toggle-ci-status-header)

(provide 'magithub-ci)
;;; magithub-ci.el ends here
