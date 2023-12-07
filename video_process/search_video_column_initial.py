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

def clear_folder(folder_path):
    for filename in os.listdir(folder_path):
        file_path = os.path.join(folder_path, filename)
        if os.path.isfile(file_path) and any(filename.lower().endswith(extension) for extension in ['.jpg', '.jpeg', '.png', '.gif']):
            os.remove(file_path)

def main():
    print("[Info] Start search video column initial!")
    img_path = "./searchVideo/searchImages"
    col_path = "./searchVideo/searchColumns"
    clear_folder(img_path)

    # f = open("/home/szr/SVDexperiment/SVDgroundtruth/gt_videos")
    # contents = f.read()
    # content = contents.split("\n") # video_name of videos in groundtruth

    frame_id = [] # frame_id column
    count = 0 # total frames
    i = 0 # tranverse frames per second

    arguments = sys.argv
    directory_path = arguments[1]

    # set model = resnet50
    model = models.resnet50()
    # freeze all layers
    for name, param in model.named_parameters():
        param.requires_grad = False
    # obtain pretrained parameters
    path = "/home/szr/simsiam/param/checkpoint_0099.pth.tar"
    print("=> loading checkpoint '{}'".format(path))
    checkpoint = torch.load(path, map_location="cpu")
    state_dict = checkpoint['state_dict']
    for k in list(state_dict.keys()):
        # retain only encoder up to before the embedding layer
        if k.startswith('module.encoder') and not k.startswith('module.encoder.fc'):
            # remove prefix
            state_dict[k[len("module.encoder."):]] = state_dict[k]
        # delete renamed or unused k
        del state_dict[k]
    msg = model.load_state_dict(state_dict, strict=False)
    #print(msg)
    assert set(msg.missing_keys) == {"fc.weight", "fc.bias"}
    print("=> loaded pre-trained model '{}'".format(path))
    # delete fc layer
    classifier = nn.Sequential()
    model.fc = classifier
    # Change the device to GPU
    device = torch.device('cuda:1' if torch.cuda.is_available() else "cpu")
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

    for dirpath, dirnames, filenames in os.walk(directory_path):
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            print("[path]",path)
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
                    cv2.imwrite(img_path + "/frame%d.jpg" % frame_count, frame)
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
    print(frame_id)
    frame_id = np.array(frame_id, 'int32')
    frame_id = frame_id.reshape(-1)
    np.save(col_path + "/frame_id.npy", frame_id)

    features = np.array(features)
    print("[feature shape]", features.shape)
    print("[feature type]", features.dtype)
    np.save(col_path + "/features.npy", features)

if __name__ == "__main__":
    main()