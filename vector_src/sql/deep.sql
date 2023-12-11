select d_id, DISTANCE(d_feature, path"/home/szr/subquery/benchmark/deepsearchvec") as dis
from DEEP
order by dis
limit 100
;