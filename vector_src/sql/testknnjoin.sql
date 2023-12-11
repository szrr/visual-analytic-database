select video_name
from search_video kNN(k=5) join dataset_video on s_feature=d_feature;