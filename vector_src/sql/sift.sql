select s_id, DISTANCE(s_feature, path"/home/szr/subquery/benchmark/siftsearchvec") as dis
from SIFT
order by dis
limit 100
;