;;; refract.el --- Refract Ruby LSP integration -*- lexical-binding: t; -*-

(require 'eglot)

(defgroup refract nil
  "Refract Ruby LSP settings."
  :group 'tools)

(defcustom refract-executable "refract"
  "Path to the refract executable."
  :type 'string
  :group 'refract)

(defcustom refract-disable-gem-index nil
  "When non-nil, skip indexing gems from Gemfile."
  :type 'boolean
  :group 'refract)

(defcustom refract-disable-rubocop nil
  "When non-nil, disable RuboCop integration."
  :type 'boolean
  :group 'refract)

(defcustom refract-max-file-size-mb 5
  "Maximum file size in MB to index."
  :type 'integer
  :group 'refract)

(defcustom refract-max-workers 4
  "Maximum parallel indexing workers."
  :type 'integer
  :group 'refract)

(defcustom refract-log-level "info"
  "Log verbosity: error, warn, info, debug."
  :type 'string
  :group 'refract)

(defcustom refract-exclude-dirs nil
  "List of directory patterns to exclude from indexing."
  :type '(repeat string)
  :group 'refract)

(defun refract--init-options ()
  "Build initialization options for refract."
  (let ((opts (list :disableGemIndex (if refract-disable-gem-index t :json-false)
                    :disableRubocop (if refract-disable-rubocop t :json-false)
                    :maxFileSizeMb refract-max-file-size-mb
                    :maxWorkers refract-max-workers
                    :logLevel refract-log-level)))
    (when refract-exclude-dirs
      (setq opts (plist-put opts :excludeDirs (vconcat refract-exclude-dirs))))
    opts))

(defclass refract-eglot-server (eglot-lsp-server) ()
  :documentation "Refract Ruby LSP server for eglot.")

(cl-defmethod eglot-initialization-options ((_server refract-eglot-server))
  (refract--init-options))

(add-to-list 'eglot-server-programs
             `((ruby-mode ruby-ts-mode) . (refract-eglot-server ,refract-executable)))

(provide 'refract)
;;; refract.el ends here
