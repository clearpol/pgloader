;;;
;;; Tools to query the PostgreSQL Schema, either source or target
;;;

(in-package :pgloader.pgsql)

(defun fetch-pgsql-catalog (dbname
                            &key table source-catalog including excluding)
  "Fetch PostgreSQL catalogs for the target database. A PostgreSQL
   connection must be opened."
  (let* ((catalog   (make-catalog :name dbname))
         (including (cond ((and table (not including))
                           (make-including-expr-from-table table))

                          ((and catalog (not including))
                           (make-including-expr-from-catalog source-catalog))

                          (t
                           including))))

    (list-all-columns catalog
                      :table-type :table
                      :including including
                      :excluding excluding)

    (list-all-indexes catalog
                      :including including
                      :excluding excluding)

    (list-all-fkeys catalog
                    :including including
                    :excluding excluding)

    (log-message :debug "fetch-pgsql-catalog: ~d tables, ~d indexes, ~d fkeys"
                 (count-tables catalog)
                 (count-indexes catalog)
                 (count-fkeys catalog))

    (when (and table (/= 1 (count-tables catalog)))
      (error "pgloader found ~d target tables for name ~s|:~{~%  ~a~}"
             (count-tables catalog)
             (format-table-name table)
             (mapcar #'format-table-name (table-list catalog))))

    catalog))

(defun make-including-expr-from-catalog (catalog)
  "Return an expression suitable to be used as an :including parameter."
  (let (including current-schema)
    ;; The schema where to install the table or view in the target database
    ;; might be different from the schema where we find it in the source
    ;; table, thanks to the ALTER TABLE ... SET SCHEMA ... feature of
    ;; pgloader.
    ;;
    ;; The schema we want to lookup here is the target schema, so it's
    ;; (table-schema table) and not the schema where we found the table in
    ;; the catalog nested structure.
    ;;
    ;; Also, MySQL schema map to PostgreSQL databases, so we might have NIL
    ;; as a schema name here. In that case, we find the current PostgreSQL
    ;; schema and use that.
    (loop :for table :in (append (table-list catalog)
                                 (view-list catalog))
       :do (let* ((schema-name
                   (or (schema-name (table-schema table))
                       current-schema
                       (setf current-schema
                             (pomo:query "select current_schema()" :single))))
                  (table-expr
                   (format-table-name-as-including-exp table))
                  (schema-entry
                   (or (assoc schema-name including :test #'string=)
                       (progn (push (cons schema-name nil) including)
                              (assoc schema-name including :test #'string=)))))
             (push-to-end table-expr (cdr schema-entry))))
    ;; return the including alist
    including))

(defun make-including-expr-from-table (table)
  "Return an expression suitable to be used as an :including parameter."
  (let ((schema (or (table-schema table)
                    (query-table-schema table))))
    (list (cons (schema-name schema)
                (list
                 (format-table-name-as-including-exp table))))))

(defun format-table-name-as-including-exp (table)
  "Return a table name suitable for a catalog lookup using ~ operator."
  (let ((table-name (table-name table)))
    (format nil "^~a$" (ensure-unquoted table-name))))

(defun ensure-unquoted (identifier)
  (cond ((pgloader.quoting::quoted-p identifier)
         ;; when the table name comes from the user (e.g. in the
         ;; load file) then we might have to unquote it: the
         ;; PostgreSQL catalogs does not store object names in
         ;; their quoted form.
         (subseq identifier 1 (1- (length identifier))))

        (t identifier)))

(defun query-table-schema (table)
  "Get PostgreSQL schema name where to locate TABLE-NAME by following the
  current search_path rules. A PostgreSQL connection must be opened."
  (make-schema :name
               (pomo:query (format nil "
  select nspname
    from pg_namespace n
    join pg_class c on n.oid = c.relnamespace
   where c.oid = '~a'::regclass;"
                                   (table-name table)) :single)))


(defvar *table-type* '((:table    . "r")
		       (:view     . "v")
                       (:index    . "i")
                       (:sequence . "S"))
  "Associate internal table type symbol with what's found in PostgreSQL
  pg_class.relkind column.")

(defun filter-list-to-where-clause (filter-list
                                    &optional
                                      not
                                      (schema-col "table_schema")
                                      (table-col  "table_name"))
  "Given an INCLUDING or EXCLUDING clause, turn it into a PostgreSQL WHERE
   clause."
  (loop :for (schema . table-name-list) :in filter-list
     :append (mapcar (lambda (table-name)
                       (format nil "(~a = '~a' and ~a ~:[~;NOT ~]~~ '~a')"
                               schema-col schema table-col not table-name))
                     table-name-list)))

(defun list-all-columns (catalog
                         &key
                           (table-type :table)
                           including
                           excluding
                         &aux
                           (table-type-name (cdr (assoc table-type *table-type*))))
  "Get the list of PostgreSQL column names per table."
  (loop :for (schema-name table-name table-oid name type typmod notnull default)
     :in
     (pomo:query (format nil "
    select nspname, relname, c.oid, attname,
           t.oid::regtype as type,
           case when atttypmod > 0 then atttypmod - 4 else null end as typmod,
           attnotnull,
           case when atthasdef then def.adsrc end as default
      from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
           left join pg_attribute a on c.oid = a.attrelid
           join pg_type t on t.oid = a.atttypid and attnum > 0
           left join pg_attrdef def on a.attrelid = def.adrelid
                                   and a.attnum = def.adnum

     where nspname !~~ '^pg_' and n.nspname <> 'information_schema'
           and relkind = '~a'
           ~:[~*~;and (~{~a~^~&~10t or ~})~]
           ~:[~*~;and (~{~a~^~&~10t and ~})~]

  order by nspname, relname, attnum"
                         table-type-name
                         including      ; do we print the clause?
                         (filter-list-to-where-clause including
                                                      nil
                                                      "n.nspname"
                                                      "c.relname")
                         excluding      ; do we print the clause?
                         (filter-list-to-where-clause excluding
                                                      nil
                                                      "n.nspname"
                                                      "c.relname")))
     :do
     (let* ((schema    (maybe-add-schema catalog schema-name))
            (table     (maybe-add-table schema table-name :oid table-oid))
            (field     (make-column :name name
                                    :type-name type
                                    :type-mod typmod
                                    :nullable (not notnull)
                                    :default default)))
       (add-field table field))
     :finally (return catalog)))

(defun list-all-indexes (catalog &key including excluding)
  "Get the list of PostgreSQL index definitions per table."
  (loop
     :for (schema-name name table-schema table-name primary unique sql conname condef)
     :in (pomo:query (format nil "
  select n.nspname,
         i.relname,
         rn.nspname,
         r.relname,
         indisprimary,
         indisunique,
         pg_get_indexdef(indexrelid),
         c.conname,
         pg_get_constraintdef(c.oid)
    from pg_index x
         join pg_class i ON i.oid = x.indexrelid
         join pg_class r ON r.oid = x.indrelid
         join pg_namespace n ON n.oid = i.relnamespace
         join pg_namespace rn ON rn.oid = r.relnamespace
         left join pg_constraint c ON c.conindid = i.oid
                                  and c.conrelid = r.oid
                                  -- filter out self-fkeys
                                  and c.confrelid <> r.oid
   where n.nspname !~~ '^pg_' and n.nspname <> 'information_schema'
         ~:[~*~;and (~{~a~^~&~10t or ~})~]
         ~:[~*~;and (~{~a~^~&~10t and ~})~]
order by n.nspname, r.relname"
                             including  ; do we print the clause?
                             (filter-list-to-where-clause including
                                                          nil
                                                          "rn.nspname"
                                                          "r.relname")
                             excluding  ; do we print the clause?
                             (filter-list-to-where-clause excluding
                                                          nil
                                                          "rn.nspname"
                                                          "r.relname")))
     :do (let* ((schema   (find-schema catalog schema-name))
                (tschema  (find-schema catalog table-schema))
                (table    (find-table tschema table-name))
                (pg-index
                 (make-index :name name
                             :schema schema
                             :table table
                             :primary primary
                             :unique unique
                             :columns nil
                             :sql sql
                             :conname (unless (eq :null conname) conname)
                             :condef  (unless (eq :null condef)  condef))))
           (maybe-add-index table name pg-index :key #'index-name))
     :finally (return catalog)))

(defun list-all-fkeys (catalog &key including excluding)
  "Get the list of PostgreSQL index definitions per table."
  (loop
     :for (schema-name table-name fschema-name ftable-name conname cols fcols
                       updrule delrule mrule deferrable deferred condef)
     :in
     (pomo:query (format nil "
 select n.nspname, c.relname, nf.nspname, cf.relname as frelname,
        conname,
        (select string_agg(attname, ',')
           from pg_attribute
          where attrelid = r.conrelid and array[attnum] <@ conkey
        ) as conkey,
        (select string_agg(attname, ',')
           from pg_attribute
          where attrelid = r.confrelid and array[attnum] <@ confkey
        ) as confkey,
        confupdtype, confdeltype, confmatchtype,
        condeferrable, condeferred,
        pg_catalog.pg_get_constraintdef(r.oid, true) as condef
   from pg_catalog.pg_constraint r
        JOIN pg_class c on r.conrelid = c.oid
        JOIN pg_namespace n on c.relnamespace = n.oid
        JOIN pg_class cf on r.confrelid = cf.oid
        JOIN pg_namespace nf on cf.relnamespace = nf.oid
   where r.contype = 'f'
         AND c.relkind = 'r' and cf.relkind = 'r'
         AND n.nspname !~~ '^pg_' and n.nspname <> 'information_schema'
         AND nf.nspname !~~ '^pg_' and nf.nspname <> 'information_schema'
         ~:[~*~;and (~{~a~^~&~10t or ~})~]
         ~:[~*~;and (~{~a~^~&~10t and ~})~]
         ~:[~*~;and (~{~a~^~&~10t or ~})~]
         ~:[~*~;and (~{~a~^~&~10t and ~})~]"
                         including      ; do we print the clause (table)?
                         (filter-list-to-where-clause including
                                                      nil
                                                      "n.nspname"
                                                      "c.relname")
                         excluding      ; do we print the clause (table)?
                         (filter-list-to-where-clause excluding
                                                      nil
                                                      "n.nspname"
                                                      "c.relname")
                         including      ; do we print the clause (ftable)?
                         (filter-list-to-where-clause including
                                                      nil
                                                      "nf.nspname"
                                                      "cf.relname")
                         excluding      ; do we print the clause (ftable)?
                         (filter-list-to-where-clause excluding
                                                      nil
                                                      "nf.nspname"
                                                      "cf.relname")))
     :do (flet ((pg-fk-rule-to-action (rule)
                  (case rule
                    (#\a "NO ACTION")
                    (#\r "RESTRICT")
                    (#\c "CASCADE")
                    (#\n "SET NULL")
                    (#\d "SET DEFAULT")))
                (pg-fk-match-rule-to-match-clause (rule)
                  (case rule
                    (#\f "FULL")
                    (#\p "PARTIAL")
                    (#\s "SIMPLE"))))
           (let* ((schema   (find-schema catalog schema-name))
                  (table    (find-table schema table-name))
                  (fschema  (find-schema catalog fschema-name))
                  (ftable   (find-table fschema ftable-name))
                  (fk
                   (make-fkey :name conname
                              :condef condef
                              :table table
                              :columns (split-sequence:split-sequence #\, cols)
                              :foreign-table ftable
                              :foreign-columns (split-sequence:split-sequence #\, fcols)
                              :update-rule (pg-fk-rule-to-action updrule)
                              :delete-rule (pg-fk-rule-to-action delrule)
                              :match-rule (pg-fk-match-rule-to-match-clause mrule)
                              :deferrable deferrable
                              :initially-deferred deferred)))
             (if (and table ftable)
                 (add-fkey table fk)
                 (log-message :notice "Foreign Key ~a is ignored, one of its table is missing from pgloader table selection"
                              conname))))
     :finally (return catalog)))



;;;
;;; Extra utilities to introspect a PostgreSQL schema.
;;;
(defun list-schemas ()
  "Return the list of PostgreSQL schemas in the already established
   PostgreSQL connection."
  (pomo:query "SELECT nspname FROM pg_catalog.pg_namespace;" :column))

(defun list-table-oids (table-names)
  "Return an hash table mapping TABLE-NAME to its OID for all table in the
   TABLE-NAMES list. A PostgreSQL connection must be established already."
  (let ((oidmap (make-hash-table :size (length table-names) :test #'equal)))
    (when table-names
      (loop :for (name oid)
         :in (pomo:query
              (format nil
                      "select n, n::regclass::oid from (values ~{('~a')~^,~}) as t(n)"
                      table-names))
         :do (setf (gethash name oidmap) oid)))
    oidmap))