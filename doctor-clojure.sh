#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do DIR="$(cd "$(dirname "$SOURCE")" && pwd)"; SOURCE="$(readlink "$SOURCE")"; [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"; done
DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

case "${1:-}" in
  --help|-h)
    echo "usage: doctor-clojure [check|fix|repair] <file>"
    exit 0
    ;;
esac

if ! command -v clojure &>/dev/null; then
  echo "error: clojure CLI is not installed" >&2
  exit 1
fi

CMD="repair"
FILE="$1"
case "$FILE" in
  check|fix|repair)
    CMD="$FILE"
    FILE="$2"
    ;;
esac

if [[ ! -f "$FILE" ]]; then
  echo "error: file not found: $FILE" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/deps.edn" << 'DEPS'
{:paths ["."]}
DEPS

cat > "$TMP/doctor_clojure.clj" << 'CLJCODE'
(ns doctor-clojure (:gen-class))
(def ^:private ok-exit 0)
(def ^:private fail-exit 1)
(def ^:private opens #{\( \[ \{})
(def ^:private closes #{\) \] \}})
(def ^:private match {\( \) \) \( \[ \] \] \[ \{ \} \} \{})
(def ^:private dname {\( :paren \) :paren \[ :bracket \] :bracket \{ :brace \} :brace})
(defn open? [c] (contains? opens c))
(defn close? [c] (contains? closes c))
(defn peer [c] (match c))
(defn kind [c] (dname c))
(defn- skip-str [s i]
  (loop [j (inc i)]
    (if (>= j (count s)) nil
      (let [c (nth s j)]
        (cond (= c \\) (recur (+ j 2)) (= c \") (inc j) :else (recur (inc j)))))))
(defn- skip-com [s i]
  (loop [j i]
    (if (or (>= j (count s)) (= (nth s j) \newline)) j (recur (inc j)))))
(defn- char-lit [s i]
  (let [j (inc i)] (if (>= j (count s)) (inc i) (inc j))))
(defn- skip-form [s i]
  (let [skip-ws (fn skip-ws [j]
                  (if (>= j (count s)) j
                    (let [c (nth s j)]
                      (cond (or (= c \space) (= c \tab) (= c \newline) (= c \return) (= c \,)) (recur (inc j))
                            (= c \;) (recur (skip-com s j))
                            :else j))))
        form-end (fn form-end [j]
                   (let [fc (nth s j nil)]
                     (cond (nil? fc) j
                           (= fc \\) (char-lit s j)
                           (= fc \") (or (skip-str s j) (count s))
                           (open? fc)
                           (loop [k (inc j) d 1]
                             (if (>= k (count s)) k
                               (let [c (nth s k)]
                                 (cond (= c \\) (recur (char-lit s k) d)
                                       (= c \") (if-let [e (skip-str s k)] (recur e d) (recur (count s) d))
                                       (= c \;) (recur (skip-com s k) d)
                                       (open? c) (recur (inc k) (inc d))
                                       (close? c) (if (= d 1) (inc k) (recur (inc k) (dec d)))
                                       (and (= c \#) (< (inc k) (count s)) (= (nth s (inc k)) \_))
                                       (recur (skip-form s (+ k 2)) d)
                                       :else (recur (inc k) d)))))
                           (close? fc) j
                           :else
                           (loop [k j]
                             (if (>= k (count s)) k
                               (let [c (nth s k)]
                                 (if (or (= c \space) (= c \newline) (= c \tab)
                                         (= c \return) (= c \,) (= c \;)
                                         (= c \") (open? c) (close? c) (= c \\))
                                   k (recur (inc k)))))))))]
    (form-end (skip-ws i))))
(defn- col-row [s idx]
  (loop [i 0 line 1 col 1]
    (if (>= i idx) {:line line :col col}
      (if (= (nth s i) \newline) (recur (inc i) (inc line) 1) (recur (inc i) line (inc col))))))
(defn- err [s i msg & [extra]]
  (merge {:ok false :message msg} (col-row s i) extra))
(defn- ok [] {:ok true :message "delimiters are balanced"})
(defn- unclosed [s i stack]
  (err s (dec i) "unclosed delimiters" {:expected (mapv peer (rseq stack)) :openers (vec (reverse stack))}))
(defn- handle-close [s i c stack]
  (if-let [top (peek stack)]
    (if (= (peer top) c) {:next (inc i) :stack (pop stack)}
      {:error (err s i "mismatched closing delimiter" {:expected (kind top) :expected-char (peer top) :found (kind c) :found-char c})})
    {:error (err s i "unexpected closing delimiter" {:found (kind c) :found-char c})}))
(defn- scan [s]
  (loop [i 0 stack []]
    (if (>= i (count s)) (if (empty? stack) {:ok true} (unclosed s i stack))
      (let [c (nth s i) n (when (< (inc i) (count s)) (nth s (inc i)))]
        (cond (= c \\) (recur (char-lit s i) stack)
              (= c \") (if-let [e (skip-str s i)] (recur e stack) (err s i "unterminated string"))
              (= c \;) (recur (skip-com s (inc i)) stack)
              (and (= c \#) (= n \_)) (recur (skip-form s (+ i 2)) stack)
              (open? c) (recur (inc i) (conj stack c))
              (close? c) (let [r (handle-close s i c stack)] (if (:error r) (:error r) (recur (:next r) (:stack r))))
              :else (recur (inc i) stack))))))
(defn delimiter-error? [s] (not (:ok (scan s))))
(defn diagnose [s] (let [r (scan s)] (if (:ok r) (ok) r)))
(defn- repair-close [stack c]
  (if-let [top (peek stack)]
    (if (= (peer top) c) {:stack (pop stack) :out (str c)} {:stack (pop stack) :out (str (peer top))})
    {:stack stack :out ""}))
(defn- repair* [s]
  (loop [i 0 stack [] chunks []]
    (if (>= i (count s))
      (let [tail (apply str (map peer (rseq stack)))] (apply str (conj chunks tail)))
      (let [c (nth s i) n (when (< (inc i) (count s)) (nth s (inc i)))]
        (cond (= c \\) (let [j (char-lit s i)] (recur j stack (conj chunks (subs s i j))))
              (= c \") (if-let [e (skip-str s i)] (recur e stack (conj chunks (subs s i e)))
                       (recur (count s) stack (conj chunks (subs s i))))
              (= c \;) (let [e (skip-com s i)] (recur e stack (conj chunks (subs s i e))))
              (and (= c \#) (= n \_)) (let [e (skip-form s (+ i 2))] (recur e stack (conj chunks (subs s i e))))
              (open? c) (recur (inc i) (conj stack c) (conj chunks (str c)))
              (close? c) (let [r (repair-close stack c)] (recur (inc i) (:stack r) (conj chunks (:out r))))
              :else (recur (inc i) stack (conj chunks (str c))))))))
(defn repair [s] (try (repair* s) (catch Exception _ s)))
(defn- exit [code msg] (println msg) (System/exit code))
(defn- cmd-check [path]
  (let [s (slurp path) r (diagnose s)]
    (if (:ok r) (exit ok-exit (str path ": ok")) (exit fail-exit (str path ":" (:line r) ":" (:col r) " " (:message r))))))
(defn- cmd-fix [path]
  (let [orig (slurp path) result (repair orig)] (spit path result) (println (str path ": fixed")) (System/exit ok-exit)))
(defn- cmd-repair [path]
  (let [s (slurp path) r (diagnose s)]
    (if (:ok r) (exit ok-exit "file is already balanced")
      (do (println (str path ":" (:line r) ":" (:col r) " " (:message r)))
          (spit path (repair s)) (println (str path ": fixed"))
          (let [r2 (diagnose (slurp path))]
            (if (:ok r2) (exit ok-exit "ok")
              (exit fail-exit (str "warning: remaining issue after fix - " path ":" (:line r2) ":" (:col r2) " " (:message r2)))))))))
(defn -main [& args]
  (let [[cmd & paths] args]
    (case cmd
      nil (exit fail-exit "usage: doctor-clojure check|fix|repair <file>")
      "--help" (exit ok-exit "usage: doctor-clojure check|fix|repair <file>")
      "-h" (exit ok-exit "usage: doctor-clojure check|fix|repair <file>")
      "check" (cmd-check (first paths))
      "fix" (cmd-fix (first paths))
      "repair" (cmd-repair (first paths))
      (exit fail-exit (str "unknown command: " cmd ". usage: doctor-clojure check|fix|repair <file>")))))
CLJCODE

ABS="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
cd "$TMP"
exec clojure -M -m doctor-clojure "$CMD" "$ABS"
