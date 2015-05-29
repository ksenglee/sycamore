;;;; -*- Lisp -*-
;;;;
;;;; Copyright (c) 2015, Rice University
;;;; All rights reserved.
;;;;
;;;;   Redistribution and use in source and binary forms, with or
;;;;   without modification, are permitted provided that the following
;;;;   conditions are met:
;;;;
;;;;   * Redistributions of source code must retain the above
;;;;     copyright notice, this list of conditions and the following
;;;;     disclaimer.
;;;;   * Redistributions in binary form must reproduce the above
;;;;     copyright notice, this list of conditions and the following
;;;;     disclaimer in the documentation and/or other materials
;;;;     provided with the distribution.
;;;;   * Neither the name of copyright holder the names of its
;;;;     contributors may be used to endorse or promote products
;;;;     derived from this software without specific prior written
;;;;     permission.
;;;;
;;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
;;;;   CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
;;;;   INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
;;;;   MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
;;;;   DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
;;;;   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;;;;   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
;;;;   USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
;;;;   AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
;;;;   LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
;;;;   ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;;;   POSSIBILITY OF SUCH DAMAGE.

(in-package :sycamore)

;; (declaim (optimize (speed 3) (safety 0)))

(deftype rope ()
  `(or string symbol rope-node null))

(defstruct rope-node
  (count 0 :type non-negative-fixnum)
  (left nil :type rope)
  (right nil :type rope))


(defun rope-count (rope)
  (etypecase rope
    (rope-node (rope-node-count rope))
    (simple-string (length rope))
    (string (length rope))
    (symbol (length (symbol-name rope)))))

(defun %rope-cat (first second)
  (make-rope-node :count (+ (rope-count first)
                            (rope-count second))
                  :left first
                  :right second))

(defun rope-cat (sequence)
  "Concatenate all ropes in SEQUENCE."
  (reduce #'%rope-cat sequence))

(defun rope (&rest args)
  "Concatenate all ropes in ARGS."
  (declare (dynamic-extent args))
  (when args (rope-cat args)))


(defun rope-string (rope &key (element-type 'character))
  "Convert the rope to a string."
  (let ((string (make-string (rope-count rope)
                             :element-type element-type)))
    (labels ((visit-string (rope i)
               (replace string rope :start1 i)
               (+ i (length rope)))
             (visit (rope i)
               (etypecase rope
                 (simple-string
                  (visit-string rope i))
                 (string
                  (visit-string rope i))
                 (symbol
                  (visit-string (symbol-name rope) i))
                 (rope-node
                  (visit (rope-node-right rope)
                         (visit (rope-node-left rope) i)))
                 (null))))
      (declare (dynamic-extent #'visit-string #'visit))
      (visit rope 0))
    string))

(defun rope-subrope (rope start end)
  (declare (type fixnum start end))
  (labels ((helper-string (rope start end)
             (make-array (- end start)
                         :element-type (array-element-type rope)
                         :displaced-to rope
                         :displaced-index-offset start)))
    (etypecase rope
      (simple-string (helper-string rope start end))
      (string (helper-string rope start end)))))

(defun rope-ref (rope i)
  "Return the character at position I."
  (declare (type rope rope)
           (type non-negative-fixnum i))
  (etypecase rope
    (rope-node
     (let* ((left (rope-node-left rope))
            (left-count (rope-count left)))
       (if (< i left-count)
           (rope-ref left i)
           (rope-ref (rope-node-right rope)
                    (- i left-count)))))
    (simple-string (aref rope i))
    (string (aref rope i))
    (symbol (aref (symbol-name rope) i))))

(defun rope-write (rope &key
                          (escape *print-escape*)
                          (stream *standard-output*))
  "Write ROPE to STREAM."
  (labels ((write-1 (rope)
             (write rope
                    :stream stream
                    :escape nil))
           (rec (rope)
             (etypecase rope
               (rope-node (rec (rope-node-left rope))
                          (rec (rope-node-right rope)))
               (simple-string (write-1 rope))
               (string (write-1 rope))
               (symbol (write-1 rope))
               (sequence (map nil #'write-1 rope)))))
    (declare (dynamic-extent #'write-1 #'rec))
    (when escape (write-char #\" stream))
    (rec rope)
    (when escape (write-char #\" stream)))
  (values))

(defvar *print-rope-string* t
  "If true, ropes are printed as Lisp strings instead of structures.")

(defmethod print-object ((object rope-node) stream)
  (if *print-rope-string*
      (rope-write object :stream stream)
      (call-next-method object stream)))



;;; Iteration ;;;
(defstruct rope-iterator
  (i 0 :type non-negative-fixnum)
  (stack nil :type list))

(defun rope-iterator-push (itr rope)
  (declare (type rope rope))
  (if rope
      (progn
        (push rope (rope-iterator-stack itr))
        (if (rope-node-p rope)
            (rope-iterator-push itr (rope-node-left rope))
            itr))
      itr))

(defun rope-iterator-pop (itr)
  (let* ((popped (pop (rope-iterator-stack itr)))
         (top (car (rope-iterator-stack itr))))
    (when (stringp popped)
      (assert (= (length popped) (rope-iterator-i itr)))
      (setf (rope-iterator-i itr) 0))
    (if (null top)
        itr
        (let ((left (rope-node-left top))
              (right (rope-node-right top)))
          (cond
            ((eq popped left)
             (rope-iterator-push itr right))
            ((eq popped right)
             (rope-iterator-pop itr))
            (t (error "Popped node is orphaned.")))))))

(defun rope-iterator-next (itr)
  (let ((top (car (rope-iterator-stack itr)))
        (i (rope-iterator-i itr)))
    (declare (type (or null string) top))
    (cond
      ((null top) nil)
      ((= i (length top))
       (rope-iterator-next (rope-iterator-pop itr)))
      ((< i (length top))
       (prog1 (aref top i)
         (incf (rope-iterator-i itr))))
      (t (error "Invalid index during rope iteration.")))))

(defun rope-iterator (rope)
  (rope-iterator-push (make-rope-iterator) rope))

(defun rope-compare-lexographic (rope-1 rope-2)
  "Compare ropes lexographically."
  (let ((itr-1 (rope-iterator rope-1))
        (itr-2 (rope-iterator rope-2)))

    (loop
       for a = (rope-iterator-next itr-1)
       for b = (rope-iterator-next itr-2)
       while (and (and a b)
                  (eql a b))
       finally (return (if a
                           (if b
                               (- (char-code a)
                                  (char-code b))
                               1)
                           (if b -1 0))))))

(defun rope-compare-fast (rope-1 rope-2)
  "Compare ropes quickly.

The resulting order is not necessarily lexographic."
  (let ((n-1 (rope-count rope-1))
        (n-2 (rope-count rope-2)))
    (if (= n-1 n-2)
        ;; Compare equal length ropes lexigraphically
        (rope-compare-lexographic rope-1 rope-2)
        ;; Compare different length ropes by size
        (- n-1 n-2))))