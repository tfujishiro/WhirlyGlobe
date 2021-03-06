/*
 *  TileQuadLoader.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 4/27/12.
 *  Copyright 2011-2013 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "GlobeMath.h"
#import "GlobeLayerViewWatcher.h"
#import "UIImage+Stuff.h"
#import <boost/math/special_functions/fpclassify.hpp>
#import "TileQuadLoader.h"
#import "DynamicTextureAtlas.h"
#import "DynamicDrawableAtlas.h"

using namespace Eigen;
using namespace WhirlyKit;

@interface WhirlyKitQuadTileLoader()
{
@public
    int defaultSphereTessX,defaultSphereTessY;
    DynamicTextureAtlas *texAtlas;
    DynamicDrawableAtlas *drawAtlas;
    bool doingUpdate;
    // Number of border texels we need in an image
    int borderTexel;
    int texelBinSize;
}

- (void)buildTile:(Quadtree::NodeInfo *)nodeInfo draw:(BasicDrawable **)draw skirtDraw:(BasicDrawable **)skirtDraw tex:(Texture **)tex texScale:(Point2f)texScale texOffset:(Point2f)texOffset lines:(bool)buildLines layer:(WhirlyKitQuadDisplayLayer *)layer imageData:(WhirlyKitLoadedImage *)imageData elevData:(WhirlyKitElevationChunk *)elevData;
- (LoadedTile *)getTile:(Quadtree::Identifier)ident;
- (void)flushUpdates:(WhirlyKitLayerThread *)layerThread;
@end

@implementation WhirlyKitLoadedTile

- (id)init
{
    self = [super init];
    if (!self)
        return nil;
    _images = [NSMutableArray array];
    
    return self;
}

@end

@implementation WhirlyKitLoadedImage

+ (WhirlyKitLoadedImage *)LoadedImageWithUIImage:(UIImage *)image
{
    WhirlyKitLoadedImage *loadImage = [[WhirlyKitLoadedImage alloc] init];
    loadImage.type = WKLoadedImageUIImage;
    loadImage.borderSize = 0;
    loadImage.imageData = image;
    CGImageRef cgImage = image.CGImage;
    loadImage.width = CGImageGetWidth(cgImage);
    loadImage.height = CGImageGetHeight(cgImage);
    
    return loadImage;
}

+ (WhirlyKitLoadedImage *)LoadedImageWithPVRTC:(NSData *)imageData size:(int)squareSize
{
    WhirlyKitLoadedImage *loadImage = [[WhirlyKitLoadedImage alloc] init];
    loadImage.type = WKLoadedImagePVRTC4;
    loadImage.borderSize = 0;
    loadImage.imageData = imageData;
    loadImage.width = loadImage.height = squareSize;
    
    return loadImage;
}

+ (WhirlyKitLoadedImage *)LoadedImageWithNSDataAsPNGorJPG:(NSData *)imageData
{
    WhirlyKitLoadedImage *loadImage = [[WhirlyKitLoadedImage alloc] init];
    loadImage.type = WKLoadedImageNSDataAsImage;
    loadImage.borderSize = 0;
    loadImage.imageData = imageData;
    loadImage.width = loadImage.height = 0;
    UIImage *texImage = [UIImage imageWithData:(NSData *)imageData];
    if (texImage)
    {
        loadImage.imageData = texImage;
        loadImage.width = CGImageGetWidth(texImage.CGImage);
        loadImage.height = CGImageGetHeight(texImage.CGImage);
        loadImage.type = WKLoadedImageUIImage;
    }
    
    return loadImage;
}

+ (WhirlyKitLoadedImage *)PlaceholderImage
{
    WhirlyKitLoadedImage *loadImage = [[WhirlyKitLoadedImage alloc] init];
    loadImage.type = WKLoadedImagePlaceholder;
    
    return loadImage;
}

- (WhirlyKit::Texture *)textureFromRawData:(NSData *)theData width:(int)theWidth height:(int)theHeight
{
    Texture *newTex = new Texture("Tile Quad Loader",theData,false);
    newTex->setWidth(theWidth);
    newTex->setHeight(theHeight);
    
    return newTex;
}

- (WhirlyKit::Texture *)buildTexture:(int)reqBorderTexel destWidth:(int)destWidth destHeight:(int)destHeight
{
    Texture *newTex = NULL;
    
    switch (_type)
    {
        case WKLoadedImageUIImage:
        {
            destWidth = (destWidth <= 0 ? _width : destWidth);
            destHeight = (destHeight <= 0 ? _height : destHeight);
            NSData *rawData = [(UIImage *)_imageData rawDataScaleWidth:destWidth height:destHeight border:reqBorderTexel];
            newTex = [self textureFromRawData:rawData width:destWidth height:destHeight];
        }
            break;
        case WKLoadedImageNSDataAsImage:
            // These are converted to UIImages on initialization.  So it must have failed.
            break;
        case WKLoadedImageNSDataRawData:
            if ([_imageData isKindOfClass:[NSData class]])
            {
                // Note: This isn't complete
                return [self textureFromRawData:(NSData *)_imageData width:_width height:_height];
            }
            break;
        case WKLoadedImagePVRTC4:
            if ([_imageData isKindOfClass:[NSData class]])
            {
                newTex = new Texture("Tile Quad Loader", (NSData *)_imageData,true);
                newTex->setWidth(_width);
                newTex->setHeight(_height);
            }
            break;
        case WKLoadedImagePlaceholder:
        default:
            break;
    }
    
    return newTex;
}

@end

namespace WhirlyKit
{
    
LoadedTile::LoadedTile()
{
    isLoading = false;
    placeholder = false;
    drawId = EmptyIdentity;
    skirtDrawId = EmptyIdentity;
    texId = EmptyIdentity;
    for (unsigned int ii=0;ii<4;ii++)
    {
        childDrawIds[ii] = EmptyIdentity;
        childSkirtDrawIds[ii] = EmptyIdentity;
    }
}
    
LoadedTile::LoadedTile(const WhirlyKit::Quadtree::Identifier &ident)
{
    nodeInfo.ident = ident;
    isLoading = false;
    placeholder = false;
    drawId = EmptyIdentity;
    skirtDrawId = EmptyIdentity;
    texId = EmptyIdentity;
    elevData = nil;
    for (unsigned int ii=0;ii<4;ii++)
    {
        childDrawIds[ii] = EmptyIdentity;
        childSkirtDrawIds[ii] = EmptyIdentity;
    }    
}

// Add the geometry and texture to the scene for a given tile
void LoadedTile::addToScene(WhirlyKitQuadTileLoader *loader,WhirlyKitQuadDisplayLayer *layer,Scene *scene,WhirlyKitLoadedImage *loadImage,WhirlyKitElevationChunk *loadElev,std::vector<WhirlyKit::ChangeRequest *> &changeRequests)
{
    // If it's a placeholder, we don't create geometry
    if (loadImage && loadImage.type == WKLoadedImagePlaceholder)
    {
        placeholder = true;
        return;
    }
    
    BasicDrawable *draw = NULL;
    BasicDrawable *skirtDraw = NULL;
    Texture *tex = NULL;
    [loader buildTile:&nodeInfo draw:&draw skirtDraw:&skirtDraw tex:(loadImage ? &tex : NULL) texScale:Point2f(1.0,1.0) texOffset:Point2f(0.0,0.0) lines:layer.lineMode layer:layer imageData:loadImage elevData:loadElev];
    drawId = draw->getId();
    skirtDrawId = (skirtDraw ? skirtDraw->getId() : EmptyIdentity);
    if (tex)
        texId = tex->getId();
    else
        texId = EmptyIdentity;

    if (tex)
    {
        if (loader->texAtlas)
        {
            loader->texAtlas->addTexture(tex, NULL, NULL, subTex, scene->getMemManager(), changeRequests, loader->borderTexel);
            [layer.layerThread requestFlush];
            if (draw)
                draw->applySubTexture(subTex);
            if (skirtDraw)
                skirtDraw->applySubTexture(subTex);
            delete tex;
        } else
            changeRequests.push_back(new AddTextureReq(tex));
    }
    
    // Now for the changes to the scenegraph
    if (loader->drawAtlas)
    {
        loader->drawAtlas->addDrawable(draw,changeRequests);
        delete draw;
        if (skirtDraw)
        {
            loader->drawAtlas->addDrawable(skirtDraw,changeRequests);
            delete skirtDraw;
        }
    } else {
        changeRequests.push_back(new AddDrawableReq(draw));
        if (skirtDraw)
            changeRequests.push_back(new AddDrawableReq(skirtDraw));
    }
    
    // Just in case, we don't have any child drawables here
    for (unsigned int ii=0;ii<4;ii++)
    {
        childDrawIds[ii] = EmptyIdentity;
        childSkirtDrawIds[ii] = EmptyIdentity;
    }
}

// Clean out the geometry and texture associated with the given tile
void LoadedTile::clearContents(WhirlyKitQuadTileLoader *loader,WhirlyKitQuadDisplayLayer *layer,Scene *scene,ChangeSet &changeRequests)
{
    if (drawId != EmptyIdentity)
    {
        if (loader->drawAtlas)
            loader->drawAtlas->removeDrawable(drawId, changeRequests);
        else
            changeRequests.push_back(new RemDrawableReq(drawId));
        drawId = EmptyIdentity;
    }
    if (skirtDrawId != EmptyIdentity)
    {
        if (loader->drawAtlas)
            loader->drawAtlas->removeDrawable(skirtDrawId, changeRequests);
        else
            changeRequests.push_back(new RemDrawableReq(skirtDrawId));
        skirtDrawId = EmptyIdentity;
    }
    if (loader->texAtlas)
    {
        if (subTex.texId != EmptyIdentity)
        {
            loader->texAtlas->removeTexture(subTex, changeRequests);
            subTex.texId = EmptyIdentity;
        }
    } else {
    if (texId != EmptyIdentity)
    {
        changeRequests.push_back(new RemTextureReq(texId));
        texId = EmptyIdentity;
    }
    }
    for (unsigned int ii=0;ii<4;ii++)
    {
        if (childDrawIds[ii] != EmptyIdentity)
        {
            if (loader->drawAtlas)
                loader->drawAtlas->removeDrawable(childDrawIds[ii], changeRequests);
            else
                changeRequests.push_back(new RemDrawableReq(childDrawIds[ii]));
        }
        if (childSkirtDrawIds[ii] != EmptyIdentity)
        {
            if (loader->drawAtlas)
                loader->drawAtlas->removeDrawable(childSkirtDrawIds[ii], changeRequests);
            else
                changeRequests.push_back(new RemDrawableReq(childSkirtDrawIds[ii]));
        }
    }
}

// Make sure a given tile overlaps the real world
bool isValidTile(WhirlyKitQuadDisplayLayer *layer,Mbr theMbr)
{    
    return (theMbr.overlaps(layer.mbr));
}

// Update based on what children are doing
void LoadedTile::updateContents(WhirlyKitQuadTileLoader *loader,WhirlyKitQuadDisplayLayer *layer,Quadtree *tree,ChangeSet &changeRequests)
{
    bool childrenExist = false;
    
    // Work through the possible children
    int whichChild = 0;
    for (unsigned int iy=0;iy<2;iy++)
        for (unsigned int ix=0;ix<2;ix++)
        {
            // Is it here?
            bool isPresent = false;
            Quadtree::Identifier childIdent(2*nodeInfo.ident.x+ix,2*nodeInfo.ident.y+iy,nodeInfo.ident.level+1);
            LoadedTile *childTile = [loader getTile:childIdent];
            isPresent = childTile && !childTile->isLoading;
            
            // If it exists, make sure we're not representing it here
            if (isPresent)
            {
                // Turn the child back off
                if (childDrawIds[whichChild] != EmptyIdentity)
                {
                    if (loader->drawAtlas)
                    {
                        loader->drawAtlas->removeDrawable(childDrawIds[whichChild], changeRequests);
                        if (childSkirtDrawIds[whichChild])
                            loader->drawAtlas->removeDrawable(childSkirtDrawIds[whichChild], changeRequests);
                    } else {
                        changeRequests.push_back(new RemDrawableReq(childDrawIds[whichChild]));
                        if (childSkirtDrawIds[whichChild])
                            changeRequests.push_back(new RemDrawableReq(childSkirtDrawIds[whichChild]));
                    }
                    childDrawIds[whichChild] = EmptyIdentity;
                    childSkirtDrawIds[whichChild] = EmptyIdentity;
                }
                
                childrenExist = true;
            } else {
                // It's not there, so make sure we're faking it with our texture
                // May need to build the geometry
                if (childDrawIds[whichChild] == EmptyIdentity)
                {
                    Quadtree::NodeInfo childInfo = tree->generateNode(childIdent);
                    if (isValidTile(layer,childInfo.mbr) && !placeholder)
                    {
                        BasicDrawable *childDraw = NULL;
                        BasicDrawable *childSkirtDraw = NULL;
                        [loader buildTile:&childInfo draw:&childDraw skirtDraw:&childSkirtDraw tex:NULL texScale:Point2f(0.5,0.5) texOffset:Point2f(0.5*ix,0.5*iy) lines:layer.lineMode layer:layer imageData:nil elevData:elevData];
                        // Set this to change the color of child drawables.  Helpfull for debugging
//                        childDraw->setColor(RGBAColor(64,64,64,255));
                        childDrawIds[whichChild] = childDraw->getId();
                        if (childSkirtDraw)
                            childSkirtDrawIds[whichChild] = childSkirtDraw->getId();
                        if (!layer.lineMode && texId)
                        {
                            childDraw->setTexId(texId);
                            if (childSkirtDraw)
                                childSkirtDraw->setTexId(texId);
                        }
                        if (loader->texAtlas)
                        {
                            if (childDraw)
                                childDraw->applySubTexture(subTex);
                            if (childSkirtDraw)
                                childSkirtDraw->applySubTexture(subTex);
                        }
                        if (loader->drawAtlas)
                        {
                            loader->drawAtlas->addDrawable(childDraw, changeRequests);
                            delete childDraw;
                            if (childSkirtDraw)
                            {
                                loader->drawAtlas->addDrawable(childSkirtDraw, changeRequests);
                                delete childSkirtDraw;
                            }
                        } else {
                            changeRequests.push_back(new AddDrawableReq(childDraw));
                            if (childSkirtDraw)
                                changeRequests.push_back(new AddDrawableReq(childSkirtDraw));
                        }
                    }
                }
            }
            
            whichChild++;
        }
    
    // No children, so turn the geometry for this tile back on
    if (!childrenExist)
    {
        if (drawId == EmptyIdentity && !placeholder)
        {
            BasicDrawable *draw = NULL;
            BasicDrawable *skirtDraw = NULL;
            [loader buildTile:&nodeInfo draw:&draw skirtDraw:&skirtDraw tex:NULL texScale:Point2f(1.0,1.0) texOffset:Point2f(0.0,0.0) lines:layer.lineMode layer:layer imageData:nil elevData:elevData];
            drawId = draw->getId();
            draw->setTexId(texId);
            if (skirtDraw)
            {
                skirtDrawId = skirtDraw->getId();
                skirtDraw->setTexId(texId);
            }
            if (loader->texAtlas)
            {
                draw->applySubTexture(subTex);
                if (skirtDraw)
                    skirtDraw->applySubTexture(subTex);
            }
            if (loader->drawAtlas)
            {
                loader->drawAtlas->addDrawable(draw, changeRequests);
                delete draw;
                if (skirtDraw)
                {
                    loader->drawAtlas->addDrawable(skirtDraw, changeRequests);
                    delete skirtDraw;
                }
            } else {
                changeRequests.push_back(new AddDrawableReq(draw));
                if (skirtDraw)
                    changeRequests.push_back(new AddDrawableReq(skirtDraw));
            }
        }
        
        // Also turn off any children that may have been on
        for (unsigned int ii=0;ii<4;ii++)
        {
            if (childDrawIds[ii] != EmptyIdentity)
            {
                if (loader->drawAtlas)
                {
                    loader->drawAtlas->removeDrawable(childDrawIds[ii], changeRequests);
                    if (childSkirtDrawIds[ii] != EmptyIdentity)
                        loader->drawAtlas->removeDrawable(childSkirtDrawIds[ii], changeRequests);
                } else {
                    changeRequests.push_back(new RemDrawableReq(childDrawIds[ii]));
                    if (childSkirtDrawIds[ii] != EmptyIdentity)
                        changeRequests.push_back(new RemDrawableReq(childSkirtDrawIds[ii]));
                }
                childDrawIds[ii] = EmptyIdentity;
                childSkirtDrawIds[ii] = EmptyIdentity;
            }
        }
    } else {
        // Make sure our representation is off
        if (drawId != EmptyIdentity)
        {
            if (loader->drawAtlas)
            {
                loader->drawAtlas->removeDrawable(drawId, changeRequests);
                if (skirtDrawId != EmptyIdentity)
                    loader->drawAtlas->removeDrawable(skirtDrawId, changeRequests);
            } else {
                changeRequests.push_back(new RemDrawableReq(drawId));
                if (skirtDrawId != EmptyIdentity)
                    changeRequests.push_back(new RemDrawableReq(skirtDrawId));
            }
            drawId = EmptyIdentity;
            skirtDrawId = EmptyIdentity;
        }
    }
    
    //    tree->Print();
}


void LoadedTile::Print(Quadtree *tree)
{
    NSLog(@"Node (%d,%d,%d), drawId = %d, texId = %d",nodeInfo.ident.x,nodeInfo.ident.y,nodeInfo.ident.level,(int)drawId,(int)texId);
    for (unsigned int ii=0;ii<4;ii++)
    {
        NSLog(@" Child %d drawId = %d",ii,(int)childDrawIds[ii]);
    }
    std::vector<Quadtree::Identifier> childIdents;
    tree->childrenForNode(nodeInfo.ident,childIdents);
    for (unsigned int ii=0;ii<childIdents.size();ii++)
        NSLog(@" Query child (%d,%d,%d)",childIdents[ii].x,childIdents[ii].y,childIdents[ii].level);
}
    
}

@implementation WhirlyKitQuadTileLoader
{
    /// Tiles we currently have loaded in the scene
    WhirlyKit::LoadedTileSet tileSet;
    
    /// Delegate used to provide images
    NSObject<WhirlyKitQuadTileImageDataSource> * __weak dataSource;
    
    // Parents to update after changes
    std::set<WhirlyKit::Quadtree::Identifier> parents;
    
    /// Change requests queued up between a begin and end
    std::vector<WhirlyKit::ChangeRequest *> changeRequests;
    
    /// How many fetches we have going at the moment
    int numFetches;
    
    NSString *name;
}

- (id)initWithDataSource:(NSObject<WhirlyKitQuadTileImageDataSource> *)inDataSource;
{
    self = [super init];
    if (self)
    {
        dataSource = inDataSource;
        _drawOffset = 0;
        _drawPriority = 0;
        _color = RGBAColor(255,255,255,255);
        _hasAlpha = false;
        numFetches = 0;
        _ignoreEdgeMatching = false;
        _minVis = DrawVisibleInvalid;
        _maxVis = DrawVisibleInvalid;
        _minPageVis = DrawVisibleInvalid;
        _maxPageVis = DrawVisibleInvalid;
        _imageType = WKTileIntRGBA;
        _useDynamicAtlas = true;
        doingUpdate = false;
        borderTexel = 0;
        _includeElev = false;
        _useElevAsZ = false;
        _tileScale = WKTileScaleNone;
        _fixedTileSize = 256;
        texelBinSize = 64;
        _textureAtlasSize = 2048;
    }
    
    return self;
}

- (id)initWithName:(NSString *)inName dataSource:(NSObject<WhirlyKitQuadTileImageDataSource> *)inDataSource
{
    self = [self initWithDataSource:inDataSource];
    name = inName;
    
    return self;
}


- (void)clear
{
    for (LoadedTileSet::iterator it = tileSet.begin();
         it != tileSet.end(); ++it)
        delete *it;    
    tileSet.clear();
    
    if (texAtlas)
    {
        delete texAtlas;
        texAtlas = NULL;
    }
    if (drawAtlas)
    {
        delete drawAtlas;
        drawAtlas = NULL;
    }
    
    numFetches = 0;

    parents.clear();
}

- (void)dealloc
{
    [self clear];
}

- (void)setQuadLayer:(WhirlyKitQuadDisplayLayer *)layer
{
    _quadLayer = layer;
    defaultSphereTessX = defaultSphereTessY = 10;
}

- (void)shutdownLayer:(WhirlyKitQuadDisplayLayer *)layer scene:(WhirlyKit::Scene *)scene
{
    [self flushUpdates:layer.layerThread];
    
    ChangeSet theChangeRequests;
    
    for (LoadedTileSet::iterator it = tileSet.begin();
         it != tileSet.end(); ++it)
    {
        LoadedTile *tile = *it;
        tile->clearContents(self,layer,scene,theChangeRequests);
    }
    
    if (texAtlas)
    {
        texAtlas->shutdown(theChangeRequests);
        delete texAtlas;
        texAtlas = NULL;
    }
    
    if (drawAtlas)
    {
        drawAtlas->shutdown(theChangeRequests);
        delete drawAtlas;
        drawAtlas = NULL;
    }
    
    [layer.layerThread addChangeRequests:(theChangeRequests)];
    
    [self clear];
}

// Helper routine for constructing the skirt around a tile
- (void)buildSkirt:(BasicDrawable *)draw pts:(std::vector<Point3f> &)pts tex:(std::vector<TexCoord> &)texCoords skirtFactor:(float)skirtFactor
{
    for (unsigned int ii=0;ii<pts.size()-1;ii++)
    {
        Point3f corners[4];
        TexCoord cornerTex[4];
        corners[0] = pts[ii];
        cornerTex[0] = texCoords[ii];
        corners[1] = pts[ii+1];
        cornerTex[1] = texCoords[ii+1];
        corners[2] = pts[ii+1] * skirtFactor;
        cornerTex[2] = texCoords[ii+1];
        corners[3] = pts[ii] * skirtFactor;
        cornerTex[3] = texCoords[ii];

        // Toss in the points, but point the normal up
        int base = draw->getNumPoints();
        for (unsigned int jj=0;jj<4;jj++)
        {
            draw->addPoint(corners[jj]);
            draw->addNormal((pts[ii]+pts[ii+1])/2.0);
            TexCoord texCoord = cornerTex[jj];
            draw->addTexCoord(texCoord);
        }
        
        // Add two triangles
        draw->addTriangle(BasicDrawable::Triangle(base+3,base+2,base+0));
        draw->addTriangle(BasicDrawable::Triangle(base+0,base+2,base+1));
    }
}

// Convert from our image type to a GL enum
- (GLenum)glFormat
{
    switch (_imageType)
    {
        case WKTileIntRGBA:
        default:
            return GL_UNSIGNED_BYTE;
            break;
        case WKTileUShort565:
            return GL_UNSIGNED_SHORT_5_6_5;
            break;
        case WKTileUShort4444:
            return GL_UNSIGNED_SHORT_4_4_4_4;
            break;
        case WKTileUShort5551:
            return GL_UNSIGNED_SHORT_5_5_5_1;
            break;
        case WKTileUByte:
            return GL_ALPHA;
            break;
        case WKTilePVRTC4:
            return GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG;
            break;
    }
    
    return GL_UNSIGNED_BYTE;
}

// Figure out the target size for an image based on our settings
- (void)texWidth:(int)width height:(int)height destWidth:(int *)destWidth destHeight:(int *)destHeight
{
    switch (_tileScale)
    {
        case WKTileScaleNone:
            *destWidth = width;
            *destHeight = height;
            break;
        case WKTileScaleDown:
        {
            int upWidth = NextPowOf2(width);
            int upHeight = NextPowOf2(height);
            
            if (upWidth > width && upWidth > 4)
                upWidth /= 2;
            if (upHeight > height && upHeight > 4)
                upHeight /= 2;

            // Note: Shouldn't be necessary
            int square = std::max(upWidth,upHeight);
            *destWidth = square;
            *destHeight = square;
        }
            break;
        case WKTileScaleUp:
        {
            int upWidth = NextPowOf2(width);
            int upHeight = NextPowOf2(height);
                        
            *destWidth = upWidth;
            *destHeight = upHeight;
        }
            break;
        case WKTileScaleFixed:
            *destWidth = *destHeight = _fixedTileSize;
            break;
    }
}

- (void)buildTile:(Quadtree::NodeInfo *)nodeInfo draw:(BasicDrawable **)draw skirtDraw:(BasicDrawable **)skirtDraw tex:(Texture **)tex texScale:(Point2f)texScale texOffset:(Point2f)texOffset lines:(bool)buildLines layer:(WhirlyKitQuadDisplayLayer *)layer imageData:(WhirlyKitLoadedImage *)loadImage elevData:(WhirlyKitElevationChunk *)elevData
{
    Mbr theMbr = nodeInfo->mbr;
    
    // Make sure this overlaps the area we care about
    Mbr mbr = layer.mbr;
    if (!theMbr.overlaps(mbr))
    {
        NSLog(@"Building bogus tile: (%d,%d,%d)",nodeInfo->ident.x,nodeInfo->ident.y,nodeInfo->ident.level);
    }
    
    // Snap to the designated area
    if (theMbr.ll().x() < mbr.ll().x())
        theMbr.ll().x() = mbr.ll().x();
    if (theMbr.ur().x() > mbr.ur().x())
        theMbr.ur().x() = mbr.ur().x();
    if (theMbr.ll().y() < mbr.ll().y())
        theMbr.ll().y() = mbr.ll().y();
    if (theMbr.ur().y() > mbr.ur().y())
        theMbr.ur().y() = mbr.ur().y();
    
    // Number of pieces at this level
    int xDim = 1<<nodeInfo->ident.level;
    int yDim = 1<<nodeInfo->ident.level;
    
    //    NSLog(@"Chunk ll = (%.4f,%.4f)  ur = (%.4f,%.4f)",mbr.ll().x(),mbr.ll().y(),mbr.ur().x(),mbr.ur().y());
    
    // Size of each chunk
    Point2f chunkSize = theMbr.ur() - theMbr.ll();
        
    int sphereTessX = defaultSphereTessX,sphereTessY = defaultSphereTessY;
    if (elevData)
    {
        sphereTessX = elevData.numX-1;
        sphereTessY = elevData.numY-1;
    }
        
    // Unit size of each tesselation in spherical mercator
    Point2f incr(chunkSize.x()/sphereTessX,chunkSize.y()/sphereTessY);
    
    // Texture increment for each tesselation
    TexCoord texIncr(1.0/(float)sphereTessX,1.0/(float)sphereTessY);
    
	// We're viewing this as a parameterization from ([0->1.0],[0->1.0]) so we'll
	//  break up these coordinates accordingly
    Point2f paramSize(1.0/(xDim*sphereTessX),1.0/(yDim*sphereTessY));
    
    // We need the corners in geographic for the cullable
    Point2f chunkLL = theMbr.ll();
    Point2f chunkUR = theMbr.ur();
    CoordSystem *coordSys = layer.coordSys;
    CoordSystemDisplayAdapter *coordAdapter = layer.scene->getCoordAdapter();
    CoordSystem *sceneCoordSys = coordAdapter->getCoordSystem();
    GeoCoord geoLL(coordSys->localToGeographic(Point3f(chunkLL.x(),chunkLL.y(),0.0)));
    GeoCoord geoUR(coordSys->localToGeographic(Point3f(chunkUR.x(),chunkUR.y(),0.0)));
    
    // Get texture (locally)
    if (tex)
    {
        if (loadImage && loadImage.type != WKLoadedImagePlaceholder)
        {
            int destWidth,destHeight;
            [self texWidth:loadImage.width height:loadImage.height destWidth:&destWidth destHeight:&destHeight];
            Texture *newTex = [loadImage buildTexture:borderTexel destWidth:destWidth destHeight:destHeight];
            
            if (newTex)
            {
                newTex->setFormat([self glFormat]);
                *tex = newTex;
            } else
                NSLog(@"Got bad image in quad tile loader.  Skipping.");
        } else
            *tex = NULL;
    }
    
    if (draw)
    {
        // We'll set up and fill in the drawable
        BasicDrawable *chunk = new BasicDrawable("Tile Quad Loader",(sphereTessX+1)*(sphereTessY+1),2*sphereTessX*sphereTessY);
        chunk->setDrawOffset(_drawOffset);
        chunk->setDrawPriority(_drawPriority);
        chunk->setVisibleRange(_minVis, _maxVis);
        chunk->setAlpha(_hasAlpha);
        chunk->setColor(_color);
        chunk->setLocalMbr(Mbr(Point2f(geoLL.x(),geoLL.y()),Point2f(geoUR.x(),geoUR.y())));
        chunk->setProgram(_programId);
        int elevEntry = 0;
        if (_includeElev)
            elevEntry = chunk->addAttribute(BDFloatType, "a_elev");
        
        // We're in line mode or the texture didn't load
        if (buildLines || (tex && !(*tex)))
        {
            chunk->setType(GL_LINES);
            
            // Two lines per cell
            for (unsigned int iy=0;iy<sphereTessY;iy++)
                for (unsigned int ix=0;ix<sphereTessX;ix++)
                {
                    Point3f org3D = coordAdapter->localToDisplay(CoordSystemConvert(coordSys,sceneCoordSys,Point3f(chunkLL.x()+ix*incr.x(),chunkLL.y()+iy*incr.y(),0.0)));
                    Point3f ptA_3D = coordAdapter->localToDisplay(CoordSystemConvert(coordSys,sceneCoordSys,Point3f(chunkLL.x()+(ix+1)*incr.x(),chunkLL.y()+iy*incr.y(),0.0)));
                    Point3f ptB_3D = coordAdapter->localToDisplay(CoordSystemConvert(coordSys,sceneCoordSys,Point3f(chunkLL.x()+ix*incr.x(),chunkLL.y()+(iy+1)*incr.y(),0.0)));
                    
                    TexCoord texCoord(ix*texIncr.x()*texScale.x()+texOffset.x(),1.0-(iy*texIncr.y()*texScale.y()+texOffset.y()));
                    
                    chunk->addPoint(org3D);
                    chunk->addNormal(org3D);
                    chunk->addTexCoord(texCoord);
                    chunk->addPoint(ptA_3D);
                    chunk->addNormal(ptA_3D);
                    chunk->addTexCoord(texCoord);
                    
                    chunk->addPoint(org3D);
                    chunk->addNormal(org3D);
                    chunk->addTexCoord(texCoord);
                    chunk->addPoint(ptB_3D);
                    chunk->addNormal(ptB_3D);
                    chunk->addTexCoord(texCoord);
                }
        } else {
            chunk->setType(GL_TRIANGLES);
            // Generate point, texture coords, and normals
            std::vector<Point3f> locs((sphereTessX+1)*(sphereTessY+1));
            std::vector<float> elevs((sphereTessX+1)*(sphereTessY+1));
            std::vector<TexCoord> texCoords((sphereTessX+1)*(sphereTessY+1));
            for (unsigned int iy=0;iy<sphereTessY+1;iy++)
                for (unsigned int ix=0;ix<sphereTessX+1;ix++)
                {
                    float locZ = 0.0;
                    if (elevData)
                    {
                        float whereX = ix*texScale.x() + elevData.numX*texOffset.x();
                        float whereY = iy*texScale.y() + elevData.numY*texOffset.y();
                        locZ = [elevData interpolateElevationAtX:whereX y:whereY];
                    }
                    elevs[iy*(sphereTessX+1)+ix] = locZ;
                    // We don't want real elevations in the mesh, just off in another attribute
                    if (!_useElevAsZ)
                        locZ = 0.0;
                    Point3f loc3D = coordAdapter->localToDisplay(CoordSystemConvert(coordSys,sceneCoordSys,Point3f(chunkLL.x()+ix*incr.x(),chunkLL.y()+iy*incr.y(),locZ)));
                    if (coordAdapter->isFlat())
                        loc3D.z() = locZ;
                    locs[iy*(sphereTessX+1)+ix] = loc3D;
                    
                    // Do the texture coordinate seperately
                    TexCoord texCoord(ix*texIncr.x()*texScale.x()+texOffset.x(),1.0-(iy*texIncr.y()*texScale.y()+texOffset.y()));
                    texCoords[iy*(sphereTessX+1)+ix] = texCoord;
                }
            
            // If there's elevation data, we need per triangle normals, which means more vertices
            if (elevData)
            {
                // Two triangles per cell
                for (unsigned int iy=0;iy<sphereTessY;iy++)
                {
                    for (unsigned int ix=0;ix<sphereTessX;ix++)
                    {
                        int startPt = chunk->getNumPoints();
                        int idx0 = (iy+1)*(sphereTessX+1)+ix;
                        Point3f ptA_0 = locs[idx0];
                        int idx1 = iy*(sphereTessX+1)+ix;
                        Point3f ptA_1 = locs[idx1];
                        int idx2 = (iy+1)*(sphereTessX+1)+(ix+1);
                        Point3f ptA_2 = locs[idx2];
                        Point3f normA = (ptA_2-ptA_1).cross(ptA_0-ptA_1);
                        normA.normalize();
                        chunk->addPoint(ptA_0);
                        chunk->addTexCoord(texCoords[idx0]);
                        chunk->addNormal(normA);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elevs[idx0]);

                        chunk->addPoint(ptA_1);
                        chunk->addTexCoord(texCoords[idx1]);
                        chunk->addNormal(normA);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elevs[idx1]);
                        
                        chunk->addPoint(ptA_2);
                        chunk->addTexCoord(texCoords[idx2]);
                        chunk->addNormal(normA);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elevs[idx2]);

                        BasicDrawable::Triangle triA,triB;
                        triA.verts[0] = startPt;
                        triA.verts[1] = startPt+1;
                        triA.verts[2] = startPt+2;
                        chunk->addTriangle(triA);
                        
                        startPt = chunk->getNumPoints();
                        idx0 = idx2;
                        Point3f ptB_0 = ptA_2;
                        idx1 = idx1;
                        Point3f ptB_1 = ptA_1;
                        idx2 = iy*(sphereTessX+1)+(ix+1);
                        Point3f ptB_2 = locs[idx2];
                        Point3f normB = (ptB_0-ptB_2).cross(ptB_1-ptB_2);
                        normB.normalize();
                        chunk->addPoint(ptB_0);
                        chunk->addTexCoord(texCoords[idx0]);
                        chunk->addNormal(normB);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elevs[idx0]);

                        chunk->addPoint(ptB_1);
                        chunk->addTexCoord(texCoords[idx1]);
                        chunk->addNormal(normB);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elevs[idx1]);
                        
                        chunk->addPoint(ptB_2);
                        chunk->addTexCoord(texCoords[idx2]);
                        chunk->addNormal(normB);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elevs[idx2]);
                        
                        triB.verts[0] = startPt;
                        triB.verts[1] = startPt+1;
                        triB.verts[2] = startPt+2;
                        chunk->addTriangle(triB);
                    }
                }

                
            } else {
                // Without elevation data we can share the vertices
                for (unsigned int iy=0;iy<sphereTessY+1;iy++)
                    for (unsigned int ix=0;ix<sphereTessX+1;ix++)
                    {
                        Point3f &loc3D = locs[iy*(sphereTessX+1)+ix];
                        float elev = elevs[iy*(sphereTessX+1)+ix];
                        
                        // And the normal
                        Point3f norm3D;
                        if (coordAdapter->isFlat())
                            norm3D = coordAdapter->normalForLocal(loc3D);
                        else
                            norm3D = loc3D;
                        
                        TexCoord &texCoord = texCoords[iy*(sphereTessX+1)+ix];
                        
                        chunk->addPoint(loc3D);
                        chunk->addNormal(norm3D);
                        chunk->addTexCoord(texCoord);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elev);                    
                    }

                // Two triangles per cell
                for (unsigned int iy=0;iy<sphereTessY;iy++)
                {
                    for (unsigned int ix=0;ix<sphereTessX;ix++)
                    {
                        BasicDrawable::Triangle triA,triB;
                        triA.verts[0] = (iy+1)*(sphereTessX+1)+ix;
                        triA.verts[1] = iy*(sphereTessX+1)+ix;
                        triA.verts[2] = (iy+1)*(sphereTessX+1)+(ix+1);
                        triB.verts[0] = triA.verts[2];
                        triB.verts[1] = triA.verts[1];
                        triB.verts[2] = iy*(sphereTessX+1)+(ix+1);
                        chunk->addTriangle(triA);
                        chunk->addTriangle(triB);
                    }
                }
            }
            
            if (!_ignoreEdgeMatching && !coordAdapter->isFlat() && skirtDraw)
            {
                // We'll set up and fill in the drawable
                BasicDrawable *skirtChunk = new BasicDrawable("Tile Quad Loader Skirt");
                skirtChunk->setDrawOffset(_drawOffset);
                skirtChunk->setDrawPriority(0);
                skirtChunk->setVisibleRange(_minVis, _maxVis);
                skirtChunk->setAlpha(_hasAlpha);
                skirtChunk->setColor(_color);
                skirtChunk->setLocalMbr(Mbr(Point2f(geoLL.x(),geoLL.y()),Point2f(geoUR.x(),geoUR.y())));
                skirtChunk->setType(GL_TRIANGLES);
                // We need the skirts rendered with the z buffer on, even if we're doing (mostly) pure sorting
                skirtChunk->setRequestZBuffer(true);
                skirtChunk->setProgram(_programId);
                
                // We'll vary the skirt size a bit.  Otherwise the fill gets ridiculous when we're looking
                //  at the very highest levels.  On the other hand, this doesn't fix a really big large/small
                //  disparity
                float skirtFactor = 0.95;
                skirtFactor = 1.0 - 0.2 / (1<<nodeInfo->ident.level);
                
                // Bottom skirt
                std::vector<Point3f> skirtLocs;
                std::vector<TexCoord> skirtTexCoords;
                for (unsigned int ix=0;ix<=sphereTessX;ix++)
                {
                    skirtLocs.push_back(locs[ix]);
                    skirtTexCoords.push_back(texCoords[ix]);
                }
                [self buildSkirt:skirtChunk pts:skirtLocs tex:skirtTexCoords skirtFactor:skirtFactor];
                // Top skirt
                skirtLocs.clear();
                skirtTexCoords.clear();
                for (int ix=sphereTessX;ix>=0;ix--)
                {
                    skirtLocs.push_back(locs[(sphereTessY)*(sphereTessX+1)+ix]);
                    skirtTexCoords.push_back(texCoords[(sphereTessY)*(sphereTessX+1)+ix]);
                }
                [self buildSkirt:skirtChunk pts:skirtLocs tex:skirtTexCoords skirtFactor:skirtFactor];
                // Left skirt
                skirtLocs.clear();
                skirtTexCoords.clear();
                for (int iy=sphereTessY;iy>=0;iy--)
                {
                    skirtLocs.push_back(locs[(sphereTessX+1)*iy+0]);
                    skirtTexCoords.push_back(texCoords[(sphereTessX+1)*iy+0]);
                }
                [self buildSkirt:skirtChunk pts:skirtLocs tex:skirtTexCoords skirtFactor:skirtFactor];
                // right skirt
                skirtLocs.clear();
                skirtTexCoords.clear();
                for (int iy=0;iy<=sphereTessY;iy++)
                {
                    skirtLocs.push_back(locs[(sphereTessX+1)*iy+(sphereTessX)]);
                    skirtTexCoords.push_back(texCoords[(sphereTessX+1)*iy+(sphereTessX)]);
                }
                [self buildSkirt:skirtChunk pts:skirtLocs tex:skirtTexCoords skirtFactor:skirtFactor];
                
                if (tex && *tex)
                    skirtChunk->setTexId((*tex)->getId());
                *skirtDraw = skirtChunk;
            }
            
            if (_coverPoles && !coordAdapter->isFlat())
            {
                // If we're at the top, toss in a few more triangles to represent that
                int maxY = 1 << nodeInfo->ident.level;
                if (nodeInfo->ident.y == maxY-1)
                {
                    TexCoord singleTexCoord(0.5,0.0);
                    // One point for the north pole
                    Point3f northPt(0,0,1.0);
                    chunk->addPoint(northPt);
                    chunk->addTexCoord(singleTexCoord);
                    chunk->addNormal(Point3f(0,0,1.0));
                    if (elevEntry != 0)
                        chunk->addAttributeValue(elevEntry, 0.0);
                    int northVert = chunk->getNumPoints()-1;
                    
                    // A line of points for the outer ring, but we can copy them
                    int startOfLine = chunk->getNumPoints();
                    int iy = sphereTessY;
                    for (unsigned int ix=0;ix<sphereTessX+1;ix++)
                    {
                        Point3f pt = locs[(iy*(sphereTessX+1)+ix)];
                        float elev = elevs[(iy*(sphereTessX+1)+ix)];
                        chunk->addPoint(pt);
                        chunk->addNormal(Point3f(0,0,1.0));
                        chunk->addTexCoord(singleTexCoord);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elev);
                    }

                    // And define the triangles
                    for (unsigned int ix=0;ix<sphereTessX;ix++)
                    {
                        BasicDrawable::Triangle tri;
                        tri.verts[0] = startOfLine+ix;
                        tri.verts[1] = startOfLine+ix+1;
                        tri.verts[2] = northVert;
                        chunk->addTriangle(tri);
                    }
                }
                
                if (nodeInfo->ident.y == 0)
                {
                    TexCoord singleTexCoord(0.5,1.0);
                    // One point for the south pole
                    Point3f southPt(0,0,-1.0);
                    chunk->addPoint(southPt);
                    chunk->addTexCoord(singleTexCoord);
                    chunk->addNormal(Point3f(0,0,-1.0));
                    if (elevEntry != 0)
                        chunk->addAttributeValue(elevEntry, 0.0);
                    int southVert = chunk->getNumPoints()-1;
                    
                    // A line of points for the outside ring, which we can copy
                    int startOfLine = chunk->getNumPoints();
                    int iy = 0;
                    for (unsigned int ix=0;ix<sphereTessX+1;ix++)
                    {
                        Point3f pt = locs[(iy*(sphereTessX+1)+ix)];
                        float elev = elevs[(iy*(sphereTessX+1)+ix)];
                        chunk->addPoint(pt);
                        chunk->addNormal(Point3f(0,0,-1.0));
                        chunk->addTexCoord(singleTexCoord);
                        if (elevEntry != 0)
                            chunk->addAttributeValue(elevEntry, elev);
                    }
                    
                    // And define the triangles
                    for (unsigned int ix=0;ix<sphereTessX;ix++)
                    {
                        BasicDrawable::Triangle tri;
                        tri.verts[0] = southVert;
                        tri.verts[1] = startOfLine+ix+1;
                        tri.verts[2] = startOfLine+ix;
                        chunk->addTriangle(tri);
                    }
                }
            }
            
            if (tex && *tex)
                chunk->setTexId((*tex)->getId());
        }
        
        *draw = chunk;
    }
}

// Look for a specific tile
- (LoadedTile *)getTile:(Quadtree::Identifier)ident
{
    LoadedTile dummyTile;
    dummyTile.nodeInfo.ident = ident;
    LoadedTileSet::iterator it = tileSet.find(&dummyTile);
    
    if (it == tileSet.end())
        return nil;
    
    return *it;
}

// Make all the various parents update their child geometry
- (void)refreshParents:(WhirlyKitQuadDisplayLayer *)layer
{
    // Update just the parents that have changed recently
    for (std::set<Quadtree::Identifier>::iterator it = parents.begin();
         it != parents.end(); ++it)
    {
        LoadedTile *theTile = [self getTile:*it];
        if (theTile && !theTile->isLoading)
        {
//            NSLog(@"Updating parent (%d,%d,%d)",theTile->nodeInfo.ident.x,theTile->nodeInfo.ident.y,
//                  theTile->nodeInfo.ident.level);
            theTile->updateContents(self, layer, layer.quadtree, changeRequests);
        }
    }
    parents.clear();
}

// This is not used, but it gets rid of the @selector warning below
- (void)wakeUp
{
}

// Flush out any outstanding updates saved in the changeRequests
- (void)flushUpdates:(WhirlyKitLayerThread *)layerThread
{
    if (drawAtlas)
    {
        if (drawAtlas->hasUpdates() && !drawAtlas->waitingOnSwap())
            drawAtlas->swap(changeRequests,_quadLayer,@selector(wakeUp));
    }
    if (!changeRequests.empty())
    {
        [layerThread addChangeRequests:(changeRequests)];
        changeRequests.clear();
//        [layerThread flushChangeRequests];
    }
}

// Dump out some information on resource usage
- (void)log
{
    if (!drawAtlas && !texAtlas)
        return;
    
    NSLog(@"++ Quad Tile Loader %@ ++",(name ? name : @"Unknown"));
    if (drawAtlas)
        drawAtlas->log();
    if (texAtlas)
        texAtlas->log();
    NSLog(@"++ ++ ++");
}

#pragma mark - Loader delegate

// We can do another fetch if we haven't hit the max
- (bool)isReady
{
    // Make sure we're not fetching too much at once
    if (numFetches >= [dataSource maxSimultaneousFetches])
        return false;
    
    // And make sure we're not waiting on buffer switches
    if (drawAtlas && drawAtlas->waitingOnSwap())
        return false;
    
    return true;
}

// Ask the data source to start loading the image for this tile
- (void)quadDisplayLayer:(WhirlyKitQuadDisplayLayer *)layer loadTile:(WhirlyKit::Quadtree::NodeInfo)tileInfo
{
    // Build the new tile
    LoadedTile *newTile = new LoadedTile();
    newTile->nodeInfo = tileInfo;
    newTile->isLoading = true;

    tileSet.insert(newTile);
    numFetches++;
    [dataSource quadTileLoader:self startFetchForLevel:tileInfo.ident.level col:tileInfo.ident.x row:tileInfo.ident.y attrs:tileInfo.attrs];
}

// Check if we're in the process of loading the given tile
- (bool)quadDisplayLayer:(WhirlyKitQuadDisplayLayer *)layer canLoadChildrenOfTile:(WhirlyKit::Quadtree::NodeInfo)tileInfo
{
    LoadedTile *tile = [self getTile:tileInfo.ident];
    if (!tile)
        return false;
    
    // If it's not loading, sure
    return !tile->isLoading;
}

// The vertex size is just used for buffer size estimates
static const int SingleVertexSize = 3*sizeof(float) + 2*sizeof(float) +  4*sizeof(unsigned char) + 3*sizeof(float);
static const int SingleElementSize = sizeof(GLushort);

// When the data source loads the image, we'll get called here
- (void)dataSource:(NSObject<WhirlyKitQuadTileImageDataSource> *)inDataSource loadedImage:(NSData *)image pvrtcSize:(int)pvrtcSize forLevel:(int)level col:(int)col row:(int)row
{
    WhirlyKitLoadedImage *loadImage = [[WhirlyKitLoadedImage alloc] init];
    if (pvrtcSize != 0)
    {
        loadImage.type = WKLoadedImagePVRTC4;
        loadImage.width = loadImage.height = pvrtcSize;
        loadImage.imageData = image;
    } else {
        loadImage.type = WKLoadedImageNSDataAsImage;
        loadImage.imageData = image;
    }

    [self dataSource:inDataSource loadedImage:loadImage forLevel:level col:col row:row];
}

- (void)dataSource:(NSObject<WhirlyKitQuadTileImageDataSource> *)dataSource loadedImage:(id)loadTile forLevel:(int)level col:(int)col row:(int)row
{
    // Look for the tile
    // If it's not here, just drop this on the floor
    LoadedTile dummyTile(Quadtree::Identifier(col,row,level));
    LoadedTileSet::iterator it = tileSet.find(&dummyTile);
    numFetches--;
    if (it == tileSet.end())
        return;
    
    WhirlyKitLoadedImage *loadImage = nil;
    WhirlyKitElevationChunk *loadElev = nil;
    if ([loadTile isKindOfClass:[WhirlyKitLoadedImage class]])
        loadImage = loadTile;
    else if ([loadTile isKindOfClass:[WhirlyKitElevationChunk class]])
        loadElev = loadTile;
    else if ([loadTile isKindOfClass:[WhirlyKitLoadedTile class]])
    {
        WhirlyKitLoadedTile *toLoad = loadTile;
        if ([toLoad.images count] > 0)
            loadImage = toLoad.images[0];
        loadElev = toLoad.elevChunk;
    }
    
    // Create the dynamic texture atlas before we need it
    if (_useDynamicAtlas && !texAtlas && loadImage)
    {
        // Note: Trouble with PVRTC sub texture loading
        if (_imageType != WKTilePVRTC4)
        {
            // At 256 pixels square we can hold 64 tiles in a texture atlas.  Round up to 1k.
            int DrawBufferSize = ceil((2 * (defaultSphereTessX + 1) * (defaultSphereTessY + 1) * SingleVertexSize * 64) / 1024.0) * 1024;
            // Two triangles per grid cell in a tile
            int ElementBufferSize = ceil((2 * 6 * (defaultSphereTessX + 1) * (defaultSphereTessY + 1) * SingleElementSize * 64) / 1024.0) * 1024;
            int texSortSize = (_tileScale == WKTileScaleFixed ? _fixedTileSize : texelBinSize);
            texAtlas = new DynamicTextureAtlas(_textureAtlasSize,texSortSize,[self glFormat]);
            drawAtlas = new DynamicDrawableAtlas("Tile Quad Loader",SingleElementSize,DrawBufferSize,ElementBufferSize,_quadLayer.scene->getMemManager(),NULL,_programId);
            
            // We want some room around these
            borderTexel = 1;
        }
    }
    
    LoadedTile *tile = *it;
    tile->isLoading = false;
    if (loadImage || loadElev)
    {
        tile->elevData = loadElev;
        tile->addToScene(self,_quadLayer,_quadLayer.scene,loadImage,loadElev,changeRequests);
        [_quadLayer loader:self tileDidLoad:tile->nodeInfo.ident];
    } else {
        // Shouldn't have a visual representation, so just lose it
        [_quadLayer loader:self tileDidNotLoad:tile->nodeInfo.ident];
        tileSet.erase(it);
        delete tile;
    }

//    NSLog(@"Loaded image for tile (%d,%d,%d)",col,row,level);
    
    // Various child state changed so let's update the parents
    if (level > 0)
        parents.insert(Quadtree::Identifier(col/2,row/2,level-1));
    [self refreshParents:_quadLayer];
    
    if (!doingUpdate)
        [self flushUpdates:_quadLayer.layerThread];
}

// We'll get this before a series of unloads and loads
- (void)quadDisplayLayerStartUpdates:(WhirlyKitQuadDisplayLayer *)layer
{
    doingUpdate = true;
}

- (void)quadDisplayLayer:(WhirlyKitQuadDisplayLayer *)layer unloadTile:(WhirlyKit::Quadtree::NodeInfo)tileInfo
{
    // Get rid of an old tile
    LoadedTile dummyTile;
    dummyTile.nodeInfo.ident = tileInfo.ident;
    LoadedTileSet::iterator it = tileSet.find(&dummyTile);
    if (it != tileSet.end())
    {
        LoadedTile *theTile = *it;
        
        // Note: Debugging check
        std::vector<Quadtree::Identifier> childIDs;
        layer.quadtree->childrenForNode(theTile->nodeInfo.ident, childIDs);
        if (childIDs.size() > 0)
            NSLog(@" *** Deleting node with children *** ");
        
        theTile->clearContents(self,layer,layer.scene,changeRequests);
        tileSet.erase(it);
        delete theTile;
    }    

//    NSLog(@"Unloaded tile (%d,%d,%d)",tileInfo.ident.x,tileInfo.ident.y,tileInfo.ident.level);

    // We'll put this on the list of parents to update, but it'll actually happen in EndUpdates
    if (tileInfo.ident.level > 0)
        parents.insert(Quadtree::Identifier(tileInfo.ident.x/2,tileInfo.ident.y/2,tileInfo.ident.level-1));
}

// Thus ends the unloads.  Now we can update parents
- (void)quadDisplayLayerEndUpdates:(WhirlyKitQuadDisplayLayer *)layer
{
    [self refreshParents:layer];
    
    [self flushUpdates:layer.layerThread];
    
    doingUpdate = false;
}

// We'll try to skip updates 
- (bool)shouldUpdate:(WhirlyKitViewState *)viewState initial:(bool)isInitial
{
    bool doUpdate = true;;

    // Always do at least one
    if (isInitial)
        return true;

    // Test against the visibility range
    if ((_minVis != DrawVisibleInvalid && _maxVis != DrawVisibleInvalid) || (_minPageVis != DrawVisibleInvalid && _maxPageVis != DrawVisibleInvalid))
    {
        WhirlyGlobeViewState *globeViewState = (WhirlyGlobeViewState *)viewState;
        if ([globeViewState isKindOfClass:[WhirlyGlobeViewState class]])
        {
            if (((_minVis != DrawVisibleInvalid && _maxVis != DrawVisibleInvalid) && (globeViewState.heightAboveGlobe < _minVis || globeViewState.heightAboveGlobe > _maxVis)))
                doUpdate = false;
            if ((_minPageVis != DrawVisibleInvalid && _maxPageVis != DrawVisibleInvalid) && (globeViewState.heightAboveGlobe < _minPageVis || globeViewState.heightAboveGlobe > _maxPageVis))
                doUpdate = false;
        }
    }
    
    return doUpdate;
}

@end
