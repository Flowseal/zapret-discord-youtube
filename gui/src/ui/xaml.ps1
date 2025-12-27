# Zapret GUI - XAML Window Definition

function Get-MainWindowXaml {
    param([string]$Version)
    
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zapret GUI" 
        Height="700" Width="440"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">
    
    <Window.Resources>
        <!-- Scrollbar Thumb -->
        <Style x:Key="ScrollThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="#333333" CornerRadius="3" Margin="1"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Scrollbar -->
        <Style x:Key="CustomScrollBar" TargetType="ScrollBar">
            <Setter Property="Width" Value="6"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track Name="PART_Track" IsDirectionReversed="True">
                            <Track.Thumb>
                                <Thumb Style="{StaticResource ScrollThumb}"/>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- ScrollViewer -->
        <Style x:Key="CustomScrollViewer" TargetType="ScrollViewer">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollViewer">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <ScrollContentPresenter/>
                            <ScrollBar Grid.Column="1" Name="PART_VerticalScrollBar"
                                       Style="{StaticResource CustomScrollBar}"
                                       Value="{TemplateBinding VerticalOffset}"
                                       Maximum="{TemplateBinding ScrollableHeight}"
                                       ViewportSize="{TemplateBinding ViewportHeight}"
                                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Button -->
        <Style x:Key="MainButton" TargetType="Button">
            <Setter Property="Background" Value="#ffffff"/>
            <Setter Property="Foreground" Value="#000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Margin" Value="3"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#e0e0e0"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#222222"/>
                                <Setter Property="Foreground" Value="#444444"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Window Button -->
        <Style x:Key="WinButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#666666"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#1a1a1a"/>
                                <Setter Property="Foreground" Value="#ffffff"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Close Button -->
        <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource WinButton}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="0,16,0,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#dc2626"/>
                                <Setter Property="Foreground" Value="#ffffff"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Section -->
        <Style x:Key="Section" TargetType="Border">
            <Setter Property="Background" Value="#0a0a0a"/>
            <Setter Property="BorderBrush" Value="#1a1a1a"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Padding" Value="20"/>
            <Setter Property="Margin" Value="16,6"/>
        </Style>
        
        <!-- Section Header -->
        <Style x:Key="Header" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#ffffff"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Margin" Value="0,0,0,14"/>
        </Style>
        
        <!-- Label -->
        <Style x:Key="Label" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#666666"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>
        
        <!-- ComboBox Toggle Button -->
        <ControlTemplate x:Key="ComboBoxToggleButton" TargetType="ToggleButton">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition/>
                    <ColumnDefinition Width="20"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="Border" Grid.ColumnSpan="2" Background="#111111" BorderBrush="#222222" BorderThickness="1" CornerRadius="6"/>
                <Path x:Name="Arrow" Grid.Column="1" Fill="#666666" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M 0 0 L 4 4 L 8 0 Z"/>
            </Grid>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="Border" Property="Background" Value="#1a1a1a"/>
                    <Setter TargetName="Arrow" Property="Fill" Value="#ffffff"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>
        
        <!-- ComboBox TextBox -->
        <ControlTemplate x:Key="ComboBoxTextBox" TargetType="TextBox">
            <Border x:Name="PART_ContentHost" Focusable="False" Background="Transparent"/>
        </ControlTemplate>
        
        <!-- ComboBox Item -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#cccccc"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#222222"/>
                                <Setter Property="Foreground" Value="#ffffff"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#333333"/>
                                <Setter Property="Foreground" Value="#ffffff"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- ComboBox -->
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#111111"/>
            <Setter Property="Foreground" Value="#ffffff"/>
            <Setter Property="BorderBrush" Value="#222222"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton Name="ToggleButton" Template="{StaticResource ComboBoxToggleButton}" 
                                          Focusable="False" IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" 
                                          ClickMode="Press"/>
                            <ContentPresenter Name="ContentSite" IsHitTestVisible="False" 
                                              Content="{TemplateBinding SelectionBoxItem}" 
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" 
                                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" 
                                              Margin="14,3,30,3" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                            <Popup Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" 
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Grid Name="DropDown" SnapsToDevicePixels="True" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="200">
                                    <Border x:Name="DropDownBorder" Background="#0a0a0a" BorderBrush="#333333" BorderThickness="1" CornerRadius="6" Margin="0,2,0,0"/>
                                    <ScrollViewer Margin="4,6" SnapsToDevicePixels="True" Style="{StaticResource CustomScrollViewer}">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Grid>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    
    <Border Background="#000000" CornerRadius="16" BorderBrush="#1a1a1a" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <!-- Title Bar -->
            <Border Grid.Row="0" Background="#000000" CornerRadius="16,16,0,0" Name="TitleBar">
                <Grid>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
                        <TextBlock Text="ZAPRET" FontSize="12" FontWeight="Bold" Foreground="#ffffff"/>
                        <TextBlock Text=" v$Version" FontSize="10" Foreground="#444444" VerticalAlignment="Bottom" Margin="2,0,0,1"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Name="btnMin" Content="_" Style="{StaticResource WinButton}"/>
                        <Button Name="btnClose" Content="X" Style="{StaticResource CloseButton}"/>
                    </StackPanel>
                </Grid>
            </Border>
            
            <!-- Content -->
            <ScrollViewer Grid.Row="1" Style="{StaticResource CustomScrollViewer}">
                <StackPanel>
                    
                    <!-- Status -->
                    <Border Style="{StaticResource Section}">
                        <StackPanel>
                            <TextBlock Style="{StaticResource Header}" Text="STATUS"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="120"/>
                                    <ColumnDefinition/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                                </Grid.RowDefinitions>
                                
                                <TextBlock Grid.Row="0" Grid.Column="0" Style="{StaticResource Label}" Text="Zapret Service"/>
                                <TextBlock Grid.Row="0" Grid.Column="1" Name="txtZapret" Foreground="#555555" FontSize="11" Margin="10,0,0,6"/>
                                
                                <TextBlock Grid.Row="1" Grid.Column="0" Style="{StaticResource Label}" Text="WinDivert"/>
                                <TextBlock Grid.Row="1" Grid.Column="1" Name="txtWinDivert" Foreground="#555555" FontSize="11" Margin="10,0,0,6"/>
                                
                                <TextBlock Grid.Row="2" Grid.Column="0" Style="{StaticResource Label}" Text="Bypass Process"/>
                                <TextBlock Grid.Row="2" Grid.Column="1" Name="txtProcess" Foreground="#555555" FontSize="11" Margin="10,0,0,6"/>
                                
                                <TextBlock Grid.Row="3" Grid.Column="0" Style="{StaticResource Label}" Text="Strategy"/>
                                <TextBlock Grid.Row="3" Grid.Column="1" Name="txtStrategy" Foreground="#ffffff" FontSize="11" Margin="10,0,0,0"/>
                            </Grid>
                        </StackPanel>
                    </Border>
                    
                    <!-- Actions -->
                    <Border Style="{StaticResource Section}">
                        <StackPanel>
                            <TextBlock Style="{StaticResource Header}" Text="ACTIONS"/>
                            <Grid Margin="0,0,0,10">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Style="{StaticResource Label}" Text="Strategy" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                <ComboBox Grid.Column="1" Name="cmbStrategy" Height="34"/>
                            </Grid>
                            <UniformGrid Columns="2" Margin="-3,0">
                                <Button Name="btnInstall" Content="INSTALL" Style="{StaticResource MainButton}"/>
                                <Button Name="btnRemove" Content="REMOVE" Style="{StaticResource MainButton}"/>
                                <Button Name="btnDiag" Content="DIAGNOSTICS" Style="{StaticResource MainButton}"/>
                                <Button Name="btnTests" Content="RUN TESTS" Style="{StaticResource MainButton}"/>
                                <Button Name="btnUpdate" Content="UPDATES" Style="{StaticResource MainButton}"/>
                                <Button Name="btnRefresh" Content="REFRESH" Style="{StaticResource MainButton}"/>
                            </UniformGrid>
                        </StackPanel>
                    </Border>
                    
                    <!-- Settings -->
                    <Border Style="{StaticResource Section}">
                        <StackPanel>
                            <TextBlock Style="{StaticResource Header}" Text="SETTINGS"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="100"/>
                                    <ColumnDefinition/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition/><RowDefinition/><RowDefinition/>
                                </Grid.RowDefinitions>
                                
                                <TextBlock Grid.Row="0" Style="{StaticResource Label}" Text="Game Filter" VerticalAlignment="Center"/>
                                <Button Grid.Row="0" Grid.Column="1" Name="btnGameFilter" Content="OFF" Width="70" Style="{StaticResource MainButton}" HorizontalAlignment="Left" Margin="10,0,0,2"/>
                                
                                <TextBlock Grid.Row="1" Style="{StaticResource Label}" Text="Auto Updates" VerticalAlignment="Center"/>
                                <Button Grid.Row="1" Grid.Column="1" Name="btnAutoUpdate" Content="OFF" Width="70" Style="{StaticResource MainButton}" HorizontalAlignment="Left" Margin="10,0,0,2"/>
                                
                                <TextBlock Grid.Row="2" Style="{StaticResource Label}" Text="IPset Mode" VerticalAlignment="Center"/>
                                <Button Grid.Row="2" Grid.Column="1" Name="btnIPset" Content="none" Width="70" Style="{StaticResource MainButton}" HorizontalAlignment="Left" Margin="10,0,0,0"/>
                            </Grid>
                            <TextBlock Name="txtHint" Style="{StaticResource Label}" Text="Restart service to apply" Foreground="#333333" Margin="0,12,0,0" Visibility="Collapsed"/>
                        </StackPanel>
                    </Border>
                    
                    <!-- Log -->
                    <Border Style="{StaticResource Section}">
                        <StackPanel>
                            <Grid Margin="0,0,0,8">
                                <TextBlock Style="{StaticResource Header}" Text="LOG" Margin="0"/>
                                <Button Name="btnClear" Content="CLEAR" HorizontalAlignment="Right" Background="Transparent" Foreground="#333333" BorderThickness="0" Padding="6,2" FontSize="9" FontWeight="Bold" Cursor="Hand" VerticalAlignment="Top"/>
                            </Grid>
                            <Border Background="#050505" CornerRadius="8" Padding="10">
                                <ScrollViewer Name="logScroll" Height="70" Style="{StaticResource CustomScrollViewer}">
                                    <TextBlock Name="txtLog" Foreground="#444444" TextWrapping="Wrap" FontFamily="Consolas" FontSize="10"/>
                                </ScrollViewer>
                            </Border>
                        </StackPanel>
                    </Border>
                    
                </StackPanel>
            </ScrollViewer>
            
            <!-- Footer -->
            <Border Grid.Row="2" Background="#000000" CornerRadius="0,0,16,16" Padding="0,10,0,12">
                <TextBlock HorizontalAlignment="Center" FontSize="9" Foreground="#222222">
                    <Run Text="Design by "/><Run Text="ibuildrun" FontWeight="SemiBold" Foreground="#333333"/><Run Text="  "/><Hyperlink Name="linkGH" Foreground="#333333" TextDecorations="None">github.com/ibuildrun</Hyperlink>
                </TextBlock>
            </Border>
        </Grid>
    </Border>
</Window>
"@
}
