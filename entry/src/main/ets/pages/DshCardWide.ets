/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * DSH service card — 2x4 wide.
 * Status dot + title + detail + running count + last refresh time + refresh button.
 */
// postCardAction is a global ArkUI function (declared in the ArkUI common
// runtime), not an import from @kit.FormKit.

function statusColorWide(status: string): string {
  switch (status) {
    case 'running': return '#4CAF50';
    case 'waiting': return '#FF9800';
    case 'error': return '#F44336';
    case 'done': return '#2196F3';
    default: return '#9E9E9E';
  }
}

function statusLabelWide(status: string): string {
  switch (status) {
    case 'running': return 'Running';
    case 'waiting': return 'Waiting';
    case 'error': return 'Error';
    case 'done': return 'Done';
    default: return 'Idle';
  }
}

@Entry
@Component
struct DshCardWide {
  @LocalStorageProp('taskStatus') taskStatus: string = 'idle';
  @LocalStorageProp('taskTitle') taskTitle: string = 'DSH';
  @LocalStorageProp('taskDetail') taskDetail: string = 'No active task';
  @LocalStorageProp('updatedAt') updatedAt: string = '';
  @LocalStorageProp('runningCount') runningCount: number = 0;

  build() {
    Column({ space: 4 }) {
      // Title row
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(statusColorWide(this.taskStatus))
          .margin({ right: 6 })
        Text(this.taskTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E0E0E0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.runningCount > 0) {
          Text(`${this.runningCount} active`)
            .fontSize(11)
            .fontColor('#4CAF50')
            .margin({ left: 4 })
        }
      }
      .width('100%')

      // Detail
      Text(this.taskDetail)
        .fontSize(13)
        .fontColor('#B0B0B0')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Blank()

      // Bottom row: status + last refresh + refresh button
      Row({ space: 4 }) {
        Text(statusLabelWide(this.taskStatus))
          .fontSize(11)
          .fontColor(statusColorWide(this.taskStatus))
        Blank()
        if (this.updatedAt !== '') {
          Text(this.updatedAt)
            .fontSize(10)
            .fontColor('#808080')
        }
        // Manual refresh button — sends a refresh event to EntryAbility
        Button() {
          Text('⟳')
            .fontSize(12)
            .fontColor('#808080')
        }
        .width(24)
        .height(24)
        .backgroundColor('#2A2A3E')
        .borderRadius(12)
        .padding(0)
        .onClick(() => {
          postCardAction(this, {
            action: 'call',
            abilityName: 'EntryAbility',
            params: { method: 'onCardRefresh' }
          });
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#1A1A2E')
    .borderRadius(12)
    .onClick(() => {
      postCardAction(this, {
        action: 'call',
        abilityName: 'EntryAbility',
        params: { method: 'onCardClick' }
      });
    })
  }
}
