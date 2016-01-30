(use chicken srfi-18 extras ports)
(use forcible)

(use lolevel)

;; Bail out if we abandon a mutex.
(mutate-procedure!
 ##sys#thread-kill!
 (lambda (o)
   (lambda (t s)
     (assert (null? (##sys#slot t 8)))
     (o t s))))

(module
 test
 *
 (import (except scheme force delay))
 (import chicken srfi-18 ports extras)
 (import (only data-structures identity))
 (import forcible)

(define (dbg l v) (format (current-error-port) "D ~a ~s\n" l v) v)

(define-values (s r) (expectable 'later))
 
;;(display "Testing expectation\n" (current-error-port))
(future (begin (thread-sleep! 0.2) (s #t 42)))
(assert (force r) 42)

(assert
 (equal?
  (call-with-values (lambda () (force (delay (values 1 2)))) vector)
  '#(1 2)))

(assert
 (equal?
  (call-with-values (lambda () (force (future (values 1 2)))) vector)
  '#(1 2)))

(assert
 (equal?
  (call-with-values (lambda () (force (lazy-future (values 1 2)))) vector)
  '#(1 2)))

;; Exceptions in futures are delivered.
(assert (eq? (force (future (raise 'fail)) (lambda (ex) (eq? ex 'fail))) #t))

;; Test "order"
(assert
 (equal?
  (call-with-values (lambda () (force (order/timeout (values 1 2)))) vector)
  '#(1 2)))

;; Exceptions from order are delivered.
(assert (eq? (force (order/timeout (raise 'fail)) (lambda (ex) (eq? ex 'fail))) #t))

;; Check timeouts.
(assert (eq? (force (delay/timeout 2 (begin (thread-sleep! 0.5) 1))) 1))
(assert (force (delay/timeout 0.2 (begin (thread-sleep! 3) 'fail)) timeout-condition?))

(assert (eq? (force (future/timeout 2 (begin (thread-sleep! 0.2) 1))) 1))
(assert (eq? (force (future/timeout 0.2 (begin (thread-sleep! 3) 'fail)) timeout-condition?) #t))

(assert (eq? (force (order/timeout 0.2 (begin (thread-sleep! 3) 'fail)) timeout-condition?) #t))

;;=========================================================================
;; Reentrancy test 2: from SRFI 40 (modified)

;; Should print "Going ahead\n" just once!

(define f
  (let ((first? #t))
    (delay
     (if first?
	 (begin
	   (thread-sleep! 1)
	   (display "Going ahead\n")
	   (set! first? #f)
	   (force f))
	 'second))))

(assert
 (equal?
  (with-output-to-string
    (lambda ()
      (thread-start! (lambda () (assert (eq? (force f) 'second))))
      (assert (eq? (thread-join! (thread-start! (lambda () (force f)))) 'second))
      (assert (eq? (force f) 'second))))
  "Going ahead\n"))

;;=========================================================================
;; Memoization test 3: (pointed out by Alejandro Forero Cuervo)

(define r (delay (begin (display 'HiOnce) 1)))
(define s (lazy r))
(define t (lazy s))

(assert
 (equal?
  (with-output-to-string
    (lambda ()
      (force t)
      (force r)))
  "HiOnce"))
               ;===> Should display 'HiOnce once

;; Repeat multithreaded

(define r (delay (begin (thread-sleep! 0.1) (display 'HiOnce) 1)))
(define s (lazy r))
(define t (lazy s))

(assert
 (equal?
  (with-output-to-string
    (lambda ()
      (let ((a (future (force t))))
	(force (future (force r)))
	(force a)))))
  "HiOnce"))
               ;===> Should display 'HiOnce once

;; Test memoization of exceptions in recursive case
(dbg 'TRec '3c)
(define r (delay (begin (thread-sleep! 0.1) (display 'HiOnce) (raise 'Goodby))))
(define s (lazy r))
(define t (lazy s))

(assert
 (equal?
  (dbg 'Seen (with-output-to-string
    (lambda ()
      (let ((a (future (force t))))
	(force (future (force r)) identity)
	(force a identity)
	(force s identity)))))
  "HiOnce"))
               ;===> Should display 'HiOnce once

;=========================================================================
; Memoization test 4: Stream memoization 

(define (stream-drop s index)
  (lazy
   (if (zero? index)
       s
       (stream-drop (cdr (force s)) (- index 1)))))

(define (ones)
  (delay (begin
           (display 'ho (current-output-port))
           (cons 1 (ones)))))

(define s (ones))

(assert
 (equal?
  (with-output-to-string
    (lambda ()
      (car (force (stream-drop s 4)))
      (car (force (stream-drop s 4)))))
  "hohohohoho"))

					;===> Should display 'ho five times
;=========================================================================
; Reentrancy test 1: from R5RS

(define xcount 0)
(define p
  (delay (begin (set! xcount (+ xcount 1))
                (if (> xcount x)
                    xcount
                    (force p)))))
(define x 5)
(assert (= (force p) 6))		;===>  6
(set! x 10)
(assert (= (force p) 6))		;===>  6
       
;;=========================================================================
;; Reentrancy test 3: due to John Shutt

(define q
  (let ((count 5))
    (define (get-count) count)
    (define p (delay (if (<= count 0)
                         count
                         (begin (set! count (- count 1))
                                (force p)
                                (set! count (+ count 2))
                                count))))
    (list get-count p)))
(define get-count (car q))
(define p (cadr q))

(assert (= (get-count) 5))
(assert (= (force p) 0))
(assert (= (get-count) 10))

;; Memoization of exceptions

;; Should print "Going to raise" just once.
(define x (lazy (begin (display "\nGoing to raise\n") (raise "don't be lazy!\n"))))

(assert
 (equal?
  (with-output-to-string
    (lambda ()
      (force x (lambda (ex) (display ex)))
      (force x (lambda (ex) (display ex)))))
  "\nGoing to raise\ndon't be lazy!\ndon't be lazy!\n"))

;; Check that we will not abandon any mutex.
(assert (null? (##sys#slot (current-thread) 8)))

(define (loop) (lazy (loop)))
;(force (loop))


)
