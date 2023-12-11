select s_id, DISTANCE(s_feature, path"/home/szr/subquery/vector_src/search/siftsearch") as dis
from SIFT
where s_id < 100
order by dis
limit 50
;