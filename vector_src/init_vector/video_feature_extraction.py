"""

time:    2023/7/11
author:  szr

"This program is for initial two database columns for search video"

==input==
video_path : the path of search video

==output==
SEARCH_VIDEO0 : frame_id COLUMN
SEARCH_VIDEO1 : frame_feature COLUMN

"""

import os
import sys
import argparse
import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.parallel
import torch.backends.cudnn as cudnn
import torch.distributed as dist
import torch.optim
import torch.multiprocessing as mp
import torch.utils.data
import torch.utils.data.distributed
import torchvision.transforms as transforms
import torchvision.datasets as datasets
import torchvision.models as models

def get_box_from_file(target_string, file_path="../../vector_src/init_vector/boxes.txt"):
    with open(file_path, 'r') as file:
        for line in file:
            split_line = line.split()
            current_string = split_line[0]
            list_str = split_line[1]

            if current_string == target_string:
                return list(map(int, list_str.split(',')))
        return None

def clear_folder(folder_path):
    for filename in os.listdir(folder_path):
        file_path = os.path.join(folder_path, filename)
        if os.path.isfile(file_path) and any(filename.lower().endswith(extension) for extension in ['.jpg', '.jpeg', '.png', '.gif']):
            os.remove(file_path)

def main():
    print("[video_feature_extraction] Start search video features initial!")
    col_path = str(sys.argv[2])
    print("[video_feature_extraction] save_path :", col_path)

    # f = open("/home/szr/SVDexperiment/SVDgroundtruth/gt_videos")
    # contents = f.read()
    # content = contents.split("\n") # video_name of videos in groundtruth

    frame_id = [] # frame_id column
    count = 0 # total frames
    i = 0 # tranverse frames per second

    # set model = resnet50
    model = models.resnet50()
    # freeze all layers
    for name, param in model.named_parameters():
        param.requires_grad = False
    # obtain pretrained parameters
   # obtain pretrained parameters
    path = "/home/szr/scp/param/checkpoint_SVD_100segments_0099.pth.tar"
    # print("=> loading checkpoint '{}'".format(path))
    checkpoint = torch.load(path, map_location="cpu")
    state_dict = checkpoint['state_dict']
    fc_state_dict = {k: v for k, v in state_dict.items() if k.startswith('module.encoder.fc')}
    new_fc_state_dict = {}
    for k, v in fc_state_dict.items():
        name = k[18:]  # remove `module.` prefix
        new_fc_state_dict[name] = v
    for k in list(state_dict.keys()):
        # retain only encoder up to before the embedding layer
        if k.startswith('module.encoder') and not k.startswith('module.encoder.fc'):
            # remove prefix
            state_dict[k[len("module.encoder."):]] = state_dict[k]
        # delete renamed or unused k
        del state_dict[k]
    msg = model.load_state_dict(state_dict, strict=False)
    print(msg)
    assert set(msg.missing_keys) == {"fc.weight", "fc.bias"}
    print("=> loaded pre-trained model '{}'".format(path))
    # delete fc layer
    # classifier = nn.Sequential()
    # model.fc = classifier
    # Change the device to GPU

    fc_layer = nn.Sequential(
        nn.Linear(in_features=2048, out_features=2048, bias=False),
        nn.BatchNorm1d(2048, eps=1e-05, momentum=0.1, affine=True, track_running_stats=True),
        nn.ReLU(inplace=True),
        nn.Linear(in_features=2048, out_features=2048, bias=False),
        nn.BatchNorm1d(2048, eps=1e-05, momentum=0.1, affine=True, track_running_stats=True),
        nn.ReLU(inplace=True),
        nn.Linear(in_features=2048, out_features=128, bias=True),
        nn.BatchNorm1d(128, eps=1e-05, momentum=0.1, affine=False, track_running_stats=True)
    )
    model.fc = fc_layer
    
    # print(new_fc_state_dict)
    msg = model.fc.load_state_dict(new_fc_state_dict)
    print(msg)

    # Change the device to GPU
    device = torch.device('cuda:1' if torch.cuda.is_available() else "cpu")
    model.eval()
    model = model.to(device)
    # image normalization
    normalize = transforms.Normalize(mean=[0.485, 0.456, 0.406],
                                        std=[0.229, 0.224, 0.225])
    transform = transforms.Compose([
        transforms.ToPILImage(),
        transforms.Resize(256),
        transforms.CenterCrop(224),
        transforms.ToTensor(),
        normalize,
    ])

    features = []

    path = sys.argv[1]
    print("[video_feature_extraction] path :", path)
    vidcap = cv2.VideoCapture(path)
    success,image = vidcap.read()
    success = True
    fps = vidcap.get(cv2.CAP_PROP_FPS)
    print("[fps]", fps)
    frame_skip = int(fps)
    frame_count = 0
    while vidcap.isOpened():
        ret, frame = vidcap.read()
        if not ret:
            break
        if i > frame_skip - 1:
            frame_count += 1
            frame_id.append(frame_count) # 1, 2, 3 ...
            count+=1
            filename = os.path.basename(path)
            box = get_box_from_file(filename)
            print(box)
            
            if box != None:
                x1, y1, x2, y2 = box
                frame = frame[y1:y2, x1:x2]
            else:
                frame = frame

            img = frame
            img = transform(img)
            img = torch.unsqueeze(img, 0)
            img = img.to(device)
            # We only extract features, so we don't need gradient
            with torch.no_grad():
            # Extract the feature from the image
                feature = model(img)
                features.append(feature.cpu().detach().numpy().reshape(-1))
            i = 0
            continue
        i += 1
    features = np.array(features,dtype = 'float32')
    print("[feature shape]", features.shape)
    print("[feature type]", features.dtype)
    features = features.reshape(-1)
    # for i in range(10):
    #     print(features[i])
    features.tofile(str(sys.argv[2]))

if __name__ == "__main__":
    main()