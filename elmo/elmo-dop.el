;;; elmo-dop.el --- Modules for Disconnected Operations on ELMO.

;; Copyright (C) 1998,1999,2000 Yuuichi Teranishi <teranisi@gohome.org>

;; Author: Yuuichi Teranishi <teranisi@gohome.org>
;; Keywords: mail, net news

;; This file is part of ELMO (Elisp Library for Message Orchestration).

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.
;;

;;; Commentary:
;;

;;; Code:
;;

(require 'elmo)
(require 'elmo-vars)
(require 'elmo-msgdb)
(require 'elmo-util)
(require 'elmo-localdir)

;; global variable.
(defvar elmo-dop-queue nil
  "A list of (folder-name function-to-be-called argument-list).
Automatically loaded/saved.")

(defmacro elmo-make-dop-queue (fname method arguments)
  "Make a dop queue."
  (` (vector (, fname) (, method) (, arguments))))

(defmacro elmo-dop-queue-fname (queue)
  "Return the folder name string of the QUEUE."
  (` (aref (, queue) 0)))

(defmacro elmo-dop-queue-method (queue)
  "Return the method symbol of the QUEUE."
  (` (aref (, queue) 1)))

(defmacro elmo-dop-queue-arguments (queue)
  "Return the arguments of the QUEUE."
  (` (aref (, queue) 2)))

(defun elmo-dop-queue-append (folder method arguments)
  "Append to disconnected operation queue."
  (let ((queue (elmo-make-dop-queue (elmo-folder-name-internal folder)
				    method arguments)))
    (setq elmo-dop-queue (nconc elmo-dop-queue (list queue)))))

(defvar elmo-dop-queue-merge-method-list
  '(elmo-folder-mark-as-read
    elmo-folder-unmark-read
    elmo-folder-mark-as-important
    elmo-folder-unmark-important
    elmo-folder-mark-as-answered
    elmo-folder-unmark-answered))

(defvar elmo-dop-queue-method-name-alist
  '((elmo-folder-append-buffer-dop-delayed . "Append")
    (elmo-folder-delete-messages-dop-delayed . "Delete")
    (elmo-message-encache . "Encache")
    (elmo-folder-create-dop-delayed . "Create")
    (elmo-folder-mark-as-read . "Read")
    (elmo-folder-unmark-read . "Unread")
    (elmo-folder-mark-as-answered . "Answered")
    (elmo-folder-unmark-answered . "Unanswered")    
    (elmo-folder-mark-as-important . "Important")
    (elmo-folder-unmark-important . "Unimportant")))

(defmacro elmo-dop-queue-method-name (queue)
  `(cdr (assq (elmo-dop-queue-method ,queue)
	      elmo-dop-queue-method-name-alist)))

(defun elmo-dop-queue-flush ()
  "Flush disconnected operations that consern plugged folders."
  ;; obsolete
  (unless (or (null elmo-dop-queue)
	      (vectorp (car elmo-dop-queue)))
    (if (y-or-n-p "\
Saved queue is old version(2.6).  Clear all pending operations? ")
	(progn
	  (setq elmo-dop-queue nil)
	  (message "All pending operations are cleared.")
	  (elmo-dop-queue-save))
      (error "Please use 2.6 or earlier")))
  (elmo-dop-queue-merge)
  (let ((queue-all elmo-dop-queue)
	queue
	(count 0)
	len)
    (while queue-all
      (if (elmo-folder-plugged-p
	   (elmo-make-folder (elmo-dop-queue-fname (car queue-all))))
	  (setq queue (append queue (list (car queue-all)))))
      (setq queue-all (cdr queue-all)))
    (setq count (length queue))
    (when (> count 0)
      (if (elmo-y-or-n-p
	   (format "%d pending operation(s) exists.  Perform now? " count)
	   (not elmo-dop-flush-confirm) t)
	  (progn
	    (message "")
	    (sit-for 0)
	    (let ((queue elmo-dop-queue)
		  (performed 0)
		  (i 0)
		  (num (length elmo-dop-queue))
		  folder func failure)
	      (while queue
		;; now perform pending processes.
		(setq failure nil)
		(setq i (+ 1 i))
		(message "Flushing queue....%d/%d." i num)
		(condition-case err
		    (progn
		      (apply (elmo-dop-queue-method (car queue))
			     (prog1
				 (setq folder
				       (elmo-make-folder
					(elmo-dop-queue-fname (car queue))))
			       (elmo-folder-open folder)
			       (unless (elmo-folder-plugged-p folder)
				 (error "Unplugged")))
			     (elmo-dop-queue-arguments (car queue)))
		      (elmo-folder-close folder))
		  (quit  (setq failure t))
		  (error (setq failure err)))
		(if failure
		    ();
		  (setq elmo-dop-queue (delq (car queue) elmo-dop-queue))
		  (setq performed (+ 1 performed)))
		(setq queue (cdr queue)))
	      (message "%d/%d operation(s) are performed successfully."
		       performed num)
	      (sit-for 0) ;
	      (elmo-dop-queue-save)))
	;; when answer=NO against performing dop
	(if (elmo-y-or-n-p "Clear these pending operations? "
			   (not elmo-dop-flush-confirm) t)
	    (progn
	      (while queue
		(setq elmo-dop-queue (delq (car queue) elmo-dop-queue))
		(setq queue (cdr queue)))
	      (message "Pending operations are cleared.")
	      (elmo-dop-queue-save))
	  (message "")))
      count)))

(defun elmo-dop-queue-merge ()
  (let ((queue elmo-dop-queue)
	new-queue match-queue que)
    (while (setq que (car queue))
      (if (and
	   (memq (elmo-dop-queue-method que)
		 elmo-dop-queue-merge-method-list)
	   (setq match-queue
		 (car (delete
		       nil
		       (mapcar
			(lambda (nqueue)
			  (if (and
			       (string= (elmo-dop-queue-fname que)
					(elmo-dop-queue-fname nqueue))
			       (string= (elmo-dop-queue-method que)
					(elmo-dop-queue-method nqueue)))
			      nqueue))
			new-queue)))))
	  (setcar (elmo-dop-queue-arguments match-queue)
		  (append (car (elmo-dop-queue-arguments match-queue))
			  (car (elmo-dop-queue-arguments que))))
	(setq new-queue (nconc new-queue (list que))))
      (setq queue (cdr queue)) )
    (setq elmo-dop-queue new-queue)))

;;; dop spool folder
(defmacro elmo-dop-spool-folder (folder)
  "Return a spool folder for disconnected operations
which is corresponded to the FOLDER."
  (` (elmo-make-folder
      (concat "+" (expand-file-name "spool" (elmo-folder-msgdb-path
					     (, folder)))))))

(defun elmo-dop-spool-folder-append-buffer (folder)
  "Append current buffer content to the dop spool folder.
FOLDER is the folder structure.
Return a message number."
  (setq folder (elmo-dop-spool-folder folder))
  (unless (elmo-folder-exists-p folder)
    (elmo-folder-create folder))
  (let ((new-number (1+ (car (elmo-folder-status folder)))))
    ;; dop folder is a localdir folder.
    (write-region-as-binary (point-min) (point-max)
			  (expand-file-name
			   (int-to-string new-number)
			   (elmo-localdir-folder-directory-internal folder))
			  nil 'no-msg)
    new-number))


(defun elmo-dop-spool-folder-list-messages (folder)
  "List messages in the dop spool folder.
FOLDER is the folder structure."
  (setq folder (elmo-dop-spool-folder folder))
  (if (elmo-folder-exists-p folder)
      (elmo-folder-list-messages folder)))

(defun elmo-dop-list-deleting-messages (folder)
  "List messages which are on the deleting queue for the folder.
FOLDER is the folder structure."
  (let (messages)
    (dolist (queue elmo-dop-queue)
      (if (and (string= (elmo-dop-queue-fname queue)
			(elmo-folder-name-internal folder))
	       (eq (elmo-dop-queue-method queue)
		   'elmo-folder-delete-messages-dop-delayed))
	  (setq messages (nconc messages
				(mapcar
				 'car
				 (car (elmo-dop-queue-arguments queue)))))))))

;;; DOP operations.
(defsubst elmo-folder-append-buffer-dop (folder &optional flag number)
  (elmo-dop-queue-append
   folder 'elmo-folder-append-buffer-dop-delayed
   (list flag
	 (elmo-dop-spool-folder-append-buffer
	  folder)
	 number)))

(defsubst elmo-folder-delete-messages-dop (folder numbers)
  (let ((spool-folder (elmo-dop-spool-folder folder))
	queue)
    (dolist (number numbers)
      (if (< number 0)
	  (elmo-folder-delete-messages spool-folder
				       (list (abs number))) ; delete from queue
	(setq queue (cons number queue))))
    (when queue
      (elmo-dop-queue-append folder 'elmo-folder-delete-messages-dop-delayed
			     (list
			      (mapcar
			       (lambda (number)
				 (cons number (elmo-message-field
					       folder number 'message-id)))
			       queue))))
    t))

(defsubst elmo-message-encache-dop (folder number &optional read)
  (elmo-dop-queue-append folder 'elmo-message-encache (list number read)))

(defsubst elmo-folder-create-dop (folder)
  (elmo-dop-queue-append folder 'elmo-folder-create-dop-delayed nil))

(defsubst elmo-folder-mark-as-read-dop (folder numbers)
  (elmo-dop-queue-append folder 'elmo-folder-mark-as-read (list numbers)))

(defsubst elmo-folder-unmark-read-dop (folder numbers)
  (elmo-dop-queue-append folder 'elmo-folder-unmark-read (list numbers)))

(defsubst elmo-folder-mark-as-important-dop (folder numbers)
  (elmo-dop-queue-append folder 'elmo-folder-mark-as-important (list numbers)))

(defsubst elmo-folder-unmark-important-dop (folder numbers)
  (elmo-dop-queue-append folder 'elmo-folder-unmark-important (list numbers)))

(defsubst elmo-folder-mark-as-answered-dop (folder numbers)
  (elmo-dop-queue-append folder 'elmo-folder-mark-as-answered (list numbers)))

(defsubst elmo-folder-unmark-answered-dop (folder numbers)
  (elmo-dop-queue-append folder 'elmo-folder-unmark-answered (list numbers)))

;;; Execute as subsutitute for plugged operation.
(defun elmo-folder-status-dop (folder)
  (let* ((number-alist (elmo-msgdb-number-load
			(elmo-folder-msgdb-path folder)))
	 (number-list (mapcar 'car number-alist))
	 (spool-folder (elmo-dop-spool-folder folder))
	 spool-length
	 (i 0)
	 max-num)
    (setq spool-length (or (car (if (elmo-folder-exists-p spool-folder)
				    (elmo-folder-status spool-folder))) 0))
    (setq max-num
	  (or (nth (max (- (length number-list) 1) 0) number-list)
	      0))
    (cons (+ max-num spool-length) (+ (length number-list) spool-length))))

;;; Delayed operation (executed at online status).
(defun elmo-folder-append-buffer-dop-delayed (folder flag number set-number)
  (let ((spool-folder (elmo-dop-spool-folder folder))
	failure saved dequeued)
    (with-temp-buffer
      (if (elmo-message-fetch spool-folder number
			      (elmo-make-fetch-strategy 'entire)
			      nil (current-buffer) 'unread)
	  (condition-case nil
	      (setq failure (not
			     (elmo-folder-append-buffer
			      folder
			      (if (eq flag t) nil flag) ; for compatibility
			      set-number)))
	    (error (setq failure t)))
	(setq dequeued t)) ; Already deletef from queue.
      (when failure
	;; Append failed...
	(setq saved (elmo-folder-append-buffer
		     (elmo-make-folder elmo-lost+found-folder)
		     (if (eq flag t) nil flag) ; for compatibility
		     set-number)))
      (if (and (not dequeued)    ; if dequeued, no need to delete.
	       (or (not failure) ; succeed
		   saved))       ; in lost+found
	  (elmo-folder-delete-messages spool-folder (list number)))
      t)))

(defun elmo-folder-delete-messages-dop-delayed (folder number-alist)
  (elmo-folder-delete-messages
   folder
   ;; messages are deleted only if message-id is not changed.
   (mapcar 'car
	   (elmo-delete-if
	    (lambda (pair)
	      (not (string=
		    (cdr pair)
		    (elmo-message-fetch-field folder (car pair)
					      'message-id))))
	    number-alist))))

(defun elmo-folder-create-dop-delayed (folder)
  (unless (elmo-folder-exists-p folder)
    (elmo-folder-create folder)))

;;; Util
(defun elmo-dop-msgdb (msgdb)
  (list (mapcar (function
		 (lambda (x)
		   (elmo-msgdb-overview-entity-set-number
		    x
		    (* -1
		       (elmo-msgdb-overview-entity-get-number x)))))
		(nth 0 msgdb))
	(mapcar (function
		 (lambda (x) (cons
			      (* -1 (car x))
			      (cdr x))))
		(nth 1 msgdb))
	(mapcar (function
		 (lambda (x) (cons
			      (* -1 (car x))
			      (cdr x)))) (nth 2 msgdb))))

(require 'product)
(product-provide (provide 'elmo-dop) (require 'elmo-version))

;;; elmo-dop.el ends here
