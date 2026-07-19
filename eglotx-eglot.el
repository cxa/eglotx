;;; eglotx-eglot.el --- Eglot client adapter for Eglotx  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; This optional adapter describes one capability which upstream Eglot can
;; already consume but does not advertise: a CompletionItem `textEdit' filled
;; during completion resolve.  The protocol core uses that explicit capability
;; to keep CompletionList edit ranges compact until one item is selected.
;;
;; Preset modules load this adapter automatically.  Manual core users can
;; require it explicitly.  Keeping the method here isolates the Eglot-specific
;; policy from the generic multiplexing core.

;;; Code:

(require 'cl-lib)
(require 'eglot)
(require 'eglotx)
(require 'seq)

(defun eglotx-eglot--with-resolved-text-edit (capabilities)
  "Return CAPABILITIES with completion resolve-time `textEdit' support."
  (let* ((result (copy-sequence capabilities))
         (text-document
          (copy-sequence (or (plist-get result :textDocument) nil)))
         (completion
          (copy-sequence (or (plist-get text-document :completion) nil)))
         (completion-item
          (copy-sequence (or (plist-get completion :completionItem) nil)))
         (resolve-support
          (copy-sequence
           (or (plist-get completion-item :resolveSupport) nil)))
         (properties
          (vconcat (or (plist-get resolve-support :properties) []))))
    (unless (seq-contains-p properties "textEdit" #'equal)
      (setq properties (vconcat properties ["textEdit"])))
    (setq resolve-support
          (plist-put resolve-support :properties properties)
          completion-item
          (plist-put completion-item :resolveSupport resolve-support)
          completion
          (plist-put completion :completionItem completion-item)
          text-document
          (plist-put text-document :completion completion)
          result (plist-put result :textDocument text-document))
    result))

(cl-defmethod eglot-client-capabilities ((_server eglotx-server))
  "Advertise resolve-time completion text edits for SERVER."
  (eglotx-eglot--with-resolved-text-edit (cl-call-next-method)))

(provide 'eglotx-eglot)
;;; eglotx-eglot.el ends here
